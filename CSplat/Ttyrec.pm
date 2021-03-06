use strict;
use warnings;

package CSplat::Ttyrec;

use threads;
use threads::shared;

use lib '..';
use base 'Exporter';

our @EXPORT_OK = qw/$TTYRMINSZ $TTYRMAXSZ $TTYRDEFSZ
                    clear_cached_urls ttyrec_path url_file
                    game_ttyrec_directory
                    ttyrec_file_time fetch_ttyrecs
                    tv_frame_strip is_death_ttyrec
                    ttyrecs_out_of_time_bounds request_download
                    request_cache_clear/;

use CSplat::Config;
use CSplat::Notify;
use CSplat::Xlog qw/fix_crawl_time game_unique_key desc_game xlog_str
                    xlog_hash xlog_merge/;
use CSplat::Fetch qw/fetch_url/;
use CSplat::TtyTime qw/tty_time/;
use CSplat::TtyrecList;
use CSplat::TtyrecDir;
use CSplat::TtyrecSourceDir;
use Carp;
use Date::Manip;
use LWP::Simple;
use File::Path;
use File::Spec;
use IO::Socket::INET;
use Term::TtyRec::Plus;
use Tie::Cache;
use URI::Escape qw//;
use File::Basename qw//;

# Smallest cumulative length of ttyrec that's acceptable.
our $TTYRMINSZ = 95 * 1024;

# Largest cumulative length of ttyrec. The longer it gets, the harder we
# have to work to seek to the fun parts.
our $TTYRMAXSZ = 1024 * 1024 * 1024;

# Default ttyrec length.
our $TTYRDEFSZ = 130 * 1024;

# Approximate compression of ttyrecs
my $BZ2X = 11;
my $XZ = 10;
my $GZX = 6.6;

my @FETCH_LISTENERS;

sub url_file {
  my $url = shift;
  my ($file) = $url =~ m{.*/(.*)};
  $file
}

sub clear_cached_urls {
  CSplat::TtyrecSourceDir::clear_cached_urls();
}

sub have_cached_listing_for_game {
  my $g = shift;
  my $src = CSplat::Config::game_server_ttyrec_source($g);
  $src->have_cached_listing(game_ttyrec_cache_time($g))
}

sub clear_cached_urls_for_game {
  my $g = shift;
  my $src = CSplat::Config::game_server_ttyrec_source($g);
  $src->clear_cached_listing();
}

sub ttyrecs_out_of_time_bounds {
  my $g = shift;
  my $start = tty_time($g, 'start');
  my $end = tty_time($g, 'end');

  for my $tty (split / /, $g->{ttyrecs}) {
    if (!ttyrec_between($tty, $start, $end)) {
      warn "ttyrec is not between $start and $end: ", $tty, "\n";
      return 1;
    }
  }
  undef
}

sub is_death_ttyrec {
  my ($g, $u) = @_;
  my $file = ttyrec_path($g, $u);
  # Set line delimiter to escape for sane grepping through ttyrecs.
  local $/ = "\033";
  open my $inf, '<', $file
    or do {
      warn "Couldn't open $file: $!\n";
      return;
    };
  while (<$inf>) {
    return 1 if /You die\.\.\./;
  }
  undef
}

sub fudge_size {
  my ($sz, $url) = @_;
  # Fudge size if the ttyrec is compressed.
  $sz *= $BZ2X if $url =~ /\.bz2$/;
  $sz *= $GZX if $url =~ /\.gz$/;
  $sz *= $XZ if $url =~ /\.xz$/;
  $sz
}

sub untar {
  my $tarfile = shift;
  my $tar = Archive::Tar->new($tarfile) or return;
  my $expected_ttyrec_name = File::Basename::basename($tarfile);
  print STDERR "Looking for $expected_ttyrec_name in $tarfile\n";
  my ($file) = grep(m{\Q${expected_ttyrec_name}\E$}, $tar->list_files());
  if ($file) {
    print STDERR "Extracting $file from $tarfile to $tarfile\n";
    $tar->extract_file($file, $tarfile);
  }
}

sub uncompress_ttyrec {
  my ($g, $url) = @_;
  my $ttyrec_path = ttyrec_path($g, $$url{u});
  eval {
    my $urlstr = $url->{u};
    $urlstr =~ s/\.(?:bz2|gz|xz)$//;
    my $uncompressed_path = ttyrec_path($g, $urlstr);
    if ($url->{u} =~ /\.xz$/) {
      system("xz --decompress --keep --force \Q$ttyrec_path")
        and die "Couldn't xz --decompress $$url{u}\n";
      $url->{u} =~ s/\.xz$//;
    }
    if ($url->{u} =~ /\.bz2$/) {
      system("bunzip2 --keep --force \Q$ttyrec_path")
        and die "Couldn't bunzip $url->{u}\n";
      $url->{u} =~ s/\.bz2$//;
    }
    if ($url->{u} =~ /\.gz$/) {
      system("gunzip -c \Q$ttyrec_path\E >\Q$uncompressed_path")
        and die "Couldn't gunzip $url->{u}\n";
      $url->{u} =~ s/\.gz$//;
    }
  };
  if ($@) {
    unlink($ttyrec_path);
    return 0;
  }
  return 1;
}

sub download_ttyrecs {
  my ($listener, $g, $no_checks, $turn_seek) = @_;

  # Reverse chronological order of all known ttyrecs for the game.
  my @ttyrs = reverse @{$g->{ttyrecurls}};

  my $first_ttyrec_time = $turn_seek && $turn_seek->start_time();
  print("Game " . desc_game($g) . ", eligible ttyrec list: " .
        join(", ", map($_->{u}, @ttyrs)) . "\n");

  my $fetched_ttyrec_combined_size = 0;
  my @fetched_ttyrecs;
  for my $tty (@ttyrs) {
    last if !$first_ttyrec_time && $fetched_ttyrec_combined_size >= $TTYRDEFSZ;

    my $tty_url = $tty->{u};
    CSplat::Notify::notify($listener, "Downloading $tty_url...");
    my $path = ttyrec_path($g, $tty_url);
    eval {
      fetch_url($tty_url, $path, CSplat::Config::game_server_rate_limit($g));
    };
    if ($@) {
      CSplat::Notify::notify($listener,
                             "ERROR: Failed to fetch $tty_url: $@");
      return undef;
    }
    uncompress_ttyrec($g, $tty) or do {
      CSplat::Notify::notify($listener, "ERROR: Corrupted ttyrec: $tty_url");
      return undef;
    };

    $path = ttyrec_path($g, $tty_url);

    push @fetched_ttyrecs, $tty;
    my $tty_sz = -s($path);
    $fetched_ttyrec_combined_size += $tty_sz;
    print "Considering: $tty_url, ttysz: $tty_sz, ",
          "total size: $fetched_ttyrec_combined_size, defsz: $TTYRDEFSZ\n";

    if ($first_ttyrec_time &&
        ttyrec_file_time($tty->{u}) lt $first_ttyrec_time) {
      print("First ttyrec time: $first_ttyrec_time, ttyrec time: " .
            ttyrec_file_time($tty->{u}) . ", exiting\n");
      last;
    }
  }

  @fetched_ttyrecs = reverse(@fetched_ttyrecs);
  $g->{sz} = $fetched_ttyrec_combined_size;
  $g->{ttyrecs} = join(" ", map($_->{u}, @fetched_ttyrecs));
  $g->{ttyrecurls} = \@fetched_ttyrecs;

  1
}

sub ttyrec_play_time {
  my ($g, $ttyrec, $seektime) = @_;

  my $file = ttyrec_path($g, $ttyrec);
  my $start = ttyrec_file_time($ttyrec);
  return ($start, $start, 0) if $seektime le $start;

  my $t = Term::TtyRec::Plus->new(infile => $file);

  my $last_ts;
  my $first_ts;

  my $seekdelta =
    $seektime ? int(Delta_Format(DateCalc($start, $seektime), 0, '%st'))
              : undef;

  my $pframe;
  my $frame;
  my $seek_frame_offset;
  my $last_frame_offset;
  eval {
    while (my $fref = $t->next_frame()) {
      $frame = tell($t->filehandle()) if $seekdelta;

      my $ts = $fref->{orig_timestamp};
      $first_ts = $ts unless defined $first_ts;
      $last_ts = $ts;

      $last_frame_offset = $pframe || $frame;
      if (defined($seekdelta) && !$seek_frame_offset
          && $last_ts - $first_ts >= $seekdelta)
      {
        $seek_frame_offset = $last_frame_offset;
      }

      $pframe = $frame;
    }
  };
  warn "$@" if $@;

  if (defined($seekdelta) && !defined($seek_frame_offset)) {
    $seek_frame_offset = $last_frame_offset;
  }

  return (undef, undef, undef) unless defined $first_ts;

  my $delta = int($last_ts - $first_ts);
  my $end = DateCalc($start, "+ $delta seconds");

  ($start, $end, $seek_frame_offset)
}

sub delta_seconds {
  my $delta = shift;
  return Delta_Format($delta, '%sh');
}

sub time_delta_seconds {
  my ($candidate_time, $reference_time) = @_;
  delta_seconds(DateCalc($candidate_time, $reference_time))
}

sub ttyrecs_filter_between {
  my ($game_start, $playback_start, $playback_end, @ttyrecs) = @_;

  # The first ttyrec for a game usually has a timestamp preceding the
  # actual game start time, since dgl opens the ttyrec file before
  # Crawl starts. To work around this, we resolve the game start time to
  # the ttyrec start time that is closest to the start time and <= to it.

  # Ttyrec must be within this time before game start (1hr) to be
  # considered a part of the game.
  my $oldest_ttyrec_before_start = 3600;

  my $filter_start = $playback_start;
  if ($playback_start) {
    for my $ttyrec (reverse @ttyrecs) {
      my $time = ttyrec_file_time($$ttyrec{u});
      if ($time le $playback_start) {
        if (time_delta_seconds($time, $game_start) <
            $oldest_ttyrec_before_start) {
          $filter_start = $time;
        }
        last;
      }
    }
  }

  grep(ttyrec_between($_->{u}, $filter_start, $playback_end), @ttyrecs)
}

sub game_turn_based_seek {
  my $g = shift;
  CSplat::TurnSeek->new($g)
}

sub fetch_ttyrecs {
  my ($listener, $g, $no_death_check) = @_;

  my $game_start = tty_time($g, 'start');
  my $start = $game_start;
  my $end = tty_time($g, 'end') || tty_time($g, 'time');

  my $turn_seek = game_turn_based_seek($g);
  print("Turn-based seek: ", $turn_seek->str(), "\n") if $turn_seek;

  if ($turn_seek) {
    $start = $turn_seek->start_time() || $start;
    $end = $turn_seek->end_time() || $end;
  }

  my @ttyrecs;

  @ttyrecs = find_ttyrecs_for_game_player($listener, $g) or do {
    print "No ttyrecs on server for ", desc_game($g), "?\n";
    return;
  };

  print "Ttyrecs:\n", join("\n", map($_->{u}, @ttyrecs)), "\n";

  my @filtered_ttyrecs = ttyrecs_filter_between($game_start, $start, $end,
                                                @ttyrecs);
  unless (@filtered_ttyrecs) {
    warn "No ttyrecs between $start and $end for ", desc_game($g), "\n";
    return;
  }

  # If no start time, use only the last ttyrec.
  @filtered_ttyrecs = ($filtered_ttyrecs[-1]) unless $start;

  # Copy the hashes so we can modify them safely.
  @filtered_ttyrecs = map { { %$_ } } @filtered_ttyrecs;

  $g->{ttyrecs} = join(" ", map($_->{u}, @filtered_ttyrecs));
  $g->{ttyrecurls} = \@filtered_ttyrecs;

  CSplat::TtyrecDir->lock_for_download(
    ttyrec_directory($g, $filtered_ttyrecs[0]{u}),
    sub {
      download_ttyrecs($listener, $g, $no_death_check, $turn_seek)
    })
}

sub game_ttyrec_cache_time {
  my $g = shift;
  my $end = tty_time($g, 'end') || tty_time($g, 'time');
  int(UnixDate($end, "%s"))
}

sub find_ttyrecs_for_game_player {
  my ($listener, $g) = @_;

  my $source = CSplat::Config::game_server_ttyrec_source($g);
  $source->ttyrec_urls($listener, $g, game_ttyrec_cache_time($g))
}

sub ttyrec_file_time {
  my $url = URI::Escape::uri_unescape(shift);
  my ($date) = $url =~ /(\d{4}-\d{2}-\d{2}\.\d{2}:\d{2}:\d{2})/;
  if ($date) {
    $date =~ tr/./ /;
    return ParseDate("$date UTC");
  }

  if ($url =~ /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+][\d:]+)/) {
    return ParseDate($1);
  }

  die "ttyrec url ($url) contains no date?\n";
}

sub ttyrec_between {
  my ($tty, $start, $end) = @_;
  my $pdate = ttyrec_file_time( $tty );
  ($pdate lt $end) && (!$start || $pdate ge $start)
}

sub ttyrec_directory {
  my ($g, $url) = @_;
  my $server = CSplat::Config::game_server($g);
  my $dir = CSplat::Config::ttyrec_dir() . "/$server/$g->{name}";
  mkpath( [ $dir ] ) unless -d $dir;
  $dir
}

sub ttyrec_path {
  my ($g, $url) = @_;
  my $dir = ttyrec_directory($g, $url);
  $dir . "/" . url_file($url)
}

sub game_ttyrec_directory {
  my $g = shift;
  my @ttyrecs = split / /, $g->{ttyrecs};
  ttyrec_directory($g, $ttyrecs[0])
}

sub _strip_dec {
  my $text = shift;
  $text =~ tr[\x61\x60\x7e\x6e\x7b\xb6\xa7\xbb\xab\xa8][#*.+_\\}~{{];
  $text
}

sub tv_frame_strip {
  my $rdat = shift;

  # Strip DEC graphics. Still get odd glitches at times, but way
  # better than no DEC stripping.
  $rdat =~ s/(\x0e)([^\x0f]+)/ $1 . _strip_dec($2) /ge;
  $rdat =~ s/\xe2\x97\x86/*/g;

  # Strip IBM graphics.
  $rdat =~ tr/\xB1\xB0\xF9\xFA\xFE\xDC\xEF\xF4\xF7/#*.,+_\\}~/;
  $rdat =~ tr/\x0e\x0f//d;

  # Strip unicode. Rather pricey :(
  $rdat =~ s/\xe2\x96\x92/#/g;
  $rdat =~ s/\xe2\x96\x91/*/g;
  $rdat =~ s/\xc2\xb7/./g;
  $rdat =~ s/\xe2\x88\x99/./g;
  $rdat =~ s/\xe2\x97\xa6/,/g;
  $rdat =~ s/\xe2\x97\xbc/+/g;
  $rdat =~ s/\xe2\x88\xa9/\\/g;
  $rdat =~ s/\xe2\x8c\xa0/}/g;
  $rdat =~ s/\xe2\x89\x88/~/g;
  $rdat =~ s/\xe2\x88\x86/{/g;
  $rdat =~ s/\xc2\xa7/#/g;
  $rdat =~ s/\xe2\x99\xa3/7/g;
  $rdat =~ s/\xc2\xa9/^/g;

  $rdat
}

sub fetch_request {
  my $sub = shift;

  my $tries = 25;
  # Open connection and make request.
  while ($tries-- > 0) {
    my $sock = IO::Socket::INET->new(PeerAddr => 'localhost',
                                     PeerPort => CSplat::Config::fetch_port(),
                                     Type => SOCK_STREAM,
                                     Timeout => 15);
    unless ($sock) {
      # The fetch server doesn't seem to be running, try starting it.
      my $pid = fork;
      unless ($pid) {
        print "Starting fetch server\n";
        exec "perl -I. -MCarp=verbose fetch.pl";
        exit 0;
      }
      # Give it a little time to get moving.
      sleep 1;
    }
    else {
      return $sub->($sock);
    }
  }
  die "Failed to connect to fetch server\n";
}

sub request_cache_clear {
  fetch_request(
    sub {
      my $sock = shift;
      print $sock "CLEAR\n";
      my $res = <$sock>;
      $res =~ /OK/
    } )
}

sub request_download {
  my ($g, $listener) = @_;
  fetch_request( sub { send_download_request(shift, $g, $listener) } )
}

sub send_download_request {
  my ($sock, $g, $listener) = @_;
  print $sock "G " . xlog_str($g) . "\n";

  while (my $response = <$sock>) {
    if ($response =~ /^S (.*)/) {
      chomp(my $text = $1);
      $listener->($text) if $listener;
      next;
    }

    if ($response =~ /^FAIL (.*)/) {
      chomp(my $text = $1);
      $listener->("ERROR: $text") if $listener;
    }
    return undef unless ($response || '') =~ /OK/;

    chomp $response;
    my ($xlog) = $response =~ /^OK (.*)/;
    xlog_merge($g, xlog_hash($xlog));
  }
  1
}

1;
