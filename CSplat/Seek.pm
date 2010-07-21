use strict;
use warnings;

package CSplat::Seek;
use base 'Exporter';
use lib '..';

our @EXPORT_OK = qw/tty_frame_offset clear_screen set_buildup_size/;

use CSplat::DB qw/tty_find_frame_offset tty_save_frame_offset/;
use CSplat::Ttyrec qw/ttyrec_path $TTYRDEFSZ $TTYRMINSZ tv_frame_strip/;
use CSplat::Xlog qw/desc_game_brief/;

use Term::VT102;
use Term::TtyRec::Plus;
use Fcntl qw/SEEK_SET/;
use Carp;

# A standard VT102 to grab frames from.
my $TERM_X = 80;
my $TERM_Y = 24;
my $TERM = Term::VT102->new(cols => $TERM_X, rows => $TERM_Y);

our $MS_SEEK_BEFORE = $TTYRDEFSZ;

# Default seek after is 0.5 x this.
our $MS_SEEK_AFTER  = $TTYRDEFSZ;

our $BUILDUP_SIZE = $TTYRDEFSZ * 3;

sub set_buildup_size {
  my $sz = shift;
  $BUILDUP_SIZE = $TTYRDEFSZ * ($sz || 3);
}

sub set_default_playback_multiplier {
  my $sz = shift;
  $TTYRDEFSZ *= $sz;
}

sub clear_screen {
  "\e[2J"
}

sub tv_cache_reset {
  $TERM->reset();
  $TERM->resize($TERM_X, $TERM_Y);
  $TERM->process(clear_screen() . "\ec");
}

sub tv_cache_frame {
  $TERM->process($_[0]);
}

sub tv_chattr_s {
  my $attr = shift;
  my ($fg, $bg, $bo, $fa, $st, $ul, $bl, $rv) = $TERM->attr_unpack($attr);

  my @attr;
  push @attr, 1 if $bo || $st;
  push @attr, 2 if $fa;
  push @attr, 4 if $ul;
  push @attr, 5 if $bl;
  push @attr, 7 if $rv;

  my $attrs = @attr? join(';', @attr) . ';' : '';
  "\e[0;${attrs}3$fg;4${bg}m"
}

# Return the current term contents as a single frame that can be written
# to a terminal.
sub tv_frame {
  my $frame = "\e[2J\e[0m";
  my $lastattr = '';
  for my $row (1 .. $TERM->rows()) {
    my $text = $TERM->row_text($row);
    next unless $text =~ /[^\0 ]/;

    $text =~ tr/\0/ /;
    my $tattr = $TERM->row_attr($row);
    $frame .= "\e[${row}H";
    for (my $i = 0; $i < $TERM->cols(); ++$i) {
      my $attr = substr($tattr, $i * 2, 2);
      $frame .= tv_chattr_s($attr) if $attr ne $lastattr;
      $frame .= substr($text, $i, 1);
      $lastattr = $attr;
    }
  }

  my ($x, $y, $attr) = $TERM->status();
  $frame .= "\e[$y;${x}H";
  $frame .= tv_chattr_s($attr) unless $attr eq $lastattr;

  $frame
}

sub tty_frame_offset {
  my ($g, $deep) = @_;
  my ($ttr, $offset, $stop_offset, $frame) = tty_find_frame_offset($g);
  unless ($ttr && $offset && $frame) {
    ($ttr, $offset, $stop_offset, $frame) = tty_calc_frame_offset($g, $deep);
    tty_save_frame_offset($g, $ttr, $offset, $stop_offset, $frame) if $deep;
  }
  ($ttr, $offset, $stop_offset, $frame)
}

sub tty_calc_frame_offset {
  my ($g, $deep) = @_;

  my ($seekbefore, $seekafter) = CSplat::DB::game_seek_multipliers($g);
  print "Seeking (<$seekbefore, >$seekafter) for start frame for ",
    CSplat::Xlog::desc_game($g), "\n";

  my $milestone = $g->{milestone};
  my $sz = $g->{sz};

  my $end_offset;

  my @ttyrecs = split / /, $g->{ttyrecs};

  if ($milestone) {
    die "Milestone has ", scalar(@ttyrecs), " ttyrecs!\n" if @ttyrecs > 1;

    # Work out where exactly the milestone starts.
    my $mtime = CSplat::Ttyrec::tty_time($g, 'time');
    my ($start, $end, $seek_frame_offset) =
      CSplat::Ttyrec::ttyrec_play_time($g, $ttyrecs[0], $mtime);

    die "Broken ttyrec\n" unless defined($start) && defined($end);

    # The frame involving the milestone should be treated as EOF.
    $sz = $seek_frame_offset;
    $end_offset = $sz;
  }

  my $skipsize = 0;

  my $defsz = $milestone ? $MS_SEEK_BEFORE : $TTYRDEFSZ;

  # Give more seekback to Zot games.
  if ($g->{place} =~ /^Zot/) {
    $defsz *= 2;
  }

  # If the game itself requests a specific seek, oblige.
  $defsz *= $seekbefore;

  my $delbuildup = $BUILDUP_SIZE - $TTYRDEFSZ;

  local $BUILDUP_SIZE = $defsz + $delbuildup;

  if ($sz > $defsz) {
    $skipsize = $sz - $defsz;
  }

  for my $ttyrec (split / /, $g->{ttyrecs}) {
    my $thisz = -s(ttyrec_path($g, $ttyrec));
    if ($skipsize >= $thisz) {
      $skipsize -= $thisz;
      $sz -= $thisz;
      next;
    }

    my $ignore_hp = $milestone;

    my ($ttr, $offset, $stop_offset, $frame) =
      tty_calc_offset_in($g, $deep, $ttyrec, $sz, $skipsize, $ignore_hp);

    # Seek won't presume to set a stop offset, so do so here.
    if ($milestone && !defined($stop_offset) && defined($end_offset)
        && $seekafter != -100)
    {
      print "Seek after: $seekafter\n";
      my $endpad = $MS_SEEK_AFTER;
      $endpad *= $seekafter;
      $stop_offset = $end_offset + $endpad;
    }
    return ($ttr, $offset, $stop_offset, $frame);
  }
  confess "Argh, wtf?\n";
  # WTF?
  (undef, undef, undef, undef)
}

sub tty_calc_offset_in {
  my ($g, $deep, $ttr, $rsz, $skipsz, $ignore_hp) = @_;
  if ($deep) {
    tty_find_offset_deep($g, $ttr, $rsz, $skipsz, $ignore_hp)
  }
  else {
    tty_find_offset_simple($g, $ttr, $rsz, $skipsz)
  }
}

sub frame_full_hp {
  my $line = $TERM->row_plaintext(3);
  if ($line =~ m{(?:HP|Health): (\d+)/(\d+) } && $1 <= $2) {
    return (2, $1, $2) if $1 >= $2 * 85 / 100;
    return (1, $1, $2);
  }
  (undef, undef, undef)
}

# Deep seek strategy: Look for last frame where the character had full health,
# but don't go back farther than $TTYRDEFSZ * 2.
sub tty_find_offset_deep {
  my ($g, $ttyrec, $tsz, $skip, $ignore_hp) = @_;

  my $hp = $ignore_hp ? $ignore_hp : '';
  print "Deep scanning for start frame (sz: $tsz, skip: $skip, hp_ignore: $hp) for\n" . desc_game_brief($g) . "\n";
  local $| = 1;

  tv_cache_reset();
  my $ttyfile = ttyrec_path($g, $ttyrec);
  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);

  my $size = -s $ttyfile;
  my $skipsize = 0;
  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip < $size;
  }

  if (!$skipsize) {
    return ($ttyrec, 0, undef, '');
  }

  my $prev_frame = 0;
  my $last_full_hp = 0;
  my $last_full_hp_frame = '';
  my $clr = clear_screen();
  my $building;

  my $best_type = 0;
  my $best_hp = 0;
  my $best_maxhp = 0;

  my $lastclear;
  my $lastgoodclear;
  my %stripctx;
  while (my $fref = $t->next_frame()) {
    my $frame = $t->frame();
    my $pos = tell($t->filehandle());

    my $hasclear = index($fref->{data}, $clr) > -1;

    $lastclear = $prev_frame if $hasclear;
    $lastgoodclear = $prev_frame
      if $hasclear && ($tsz - $pos) <= $BUILDUP_SIZE;

    $building = 1 if !$building && defined $lastgoodclear;

    print "Examining frame $frame ($pos / $size)\r" unless $frame % 3031;

    if ($building) {
      tv_cache_frame(tv_frame_strip(\%stripctx, $fref->{data}));
      unless ($ignore_hp) {
        my ($type, $hp, $maxhp) = frame_full_hp();
        if ($type
            && ($type > $best_type || ($type == $best_type && $hp >= $best_hp))) {
          $best_type = $type;
          $best_hp = $hp;
          $best_maxhp = $maxhp;

          $last_full_hp = $pos;
          $last_full_hp_frame = tv_frame();
        }
      }
    }

    if ($pos >= $skipsize) {
      close($t->filehandle());

      # Ack, we found no good place to build up frames from, restart
      # with a forced start point.
      unless ($building) {
        undef $t;
        $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                     time_threshold => 3);
        seek($t->filehandle(), $lastgoodclear || $lastclear || 0, SEEK_SET);
        $building = 1;
        next;
      }

      # If we have a full hp frame, return that.
      if ($last_full_hp_frame) {
        print "\nFound full hp frame $best_type ($best_hp/$best_maxhp) ",
          "with size left (", ($tsz - $last_full_hp),
          ", avg wanted: $TTYRDEFSZ)!\n";
        return ($ttyrec, $last_full_hp, undef, $last_full_hp_frame);
      }
      print "\nReturning frame at default seek ($pos / $tsz)\n";
      return ($ttyrec, $pos, undef, tv_frame());
    }
    $prev_frame = $pos;
  }
  warn "Unexpected end of ttyrec $ttyrec\n";
  (undef, undef, undef, undef)
}

# This is the lightweight seek strategy. Can be used for on-the-fly seeking.
sub tty_find_offset_simple {
  my ($g, $ttyrec, $total_size, $skip, $buildup_from) = @_;
  my $ttyfile = ttyrec_path($g, $ttyrec);

  my $size = -s $ttyfile;
  my $skipsize = 0;

  if ($skip) {
    $skipsize = $skip if $skip > 0 && $skip < $size;
  }

  my $t = Term::TtyRec::Plus->new(infile => $ttyfile,
                                  time_threshold => 3);
  my $lastclear = 0;
  my $lastgoodclear = 0;

  tv_cache_reset();

  my $prev_frame = 0;
  my $clr = clear_screen();
  my %stripctx;
  while (my $fref = $t->next_frame()) {
    if ($skipsize) {
      my $pos = tell($t->filehandle());
      $prev_frame = $pos;

      my $hasclear = index($fref->{data}, $clr) > -1;
      $lastclear = $pos if $hasclear;
      $lastgoodclear = $pos if $hasclear && $total_size - $pos >= $TTYRMINSZ;

      if ($buildup_from && $pos >= $buildup_from) {
        tv_cache_frame(tv_frame_strip(\%stripctx, $fref->{data}));
      }

      next if $pos < $skipsize;

      if ($hasclear) {
        my $size_left = $total_size - $pos;
        if ($size_left < $TTYRMINSZ && $lastgoodclear < $pos
            && $total_size - $lastgoodclear >= $TTYRMINSZ
            && !$buildup_from)
        {
          close($t->filehandle());
          return tty_find_offset_simple($g, $ttyrec, $total_size,
                                        $skipsize, $lastgoodclear);
        }

        undef $skipsize;
      } else {
        # If we've been building up a frame in our VT102, spit that out now.
        if ($buildup_from && $buildup_from < $pos) {
          close($t->filehandle());
          return ($ttyrec, $pos, undef, tv_frame());
        }
        next;
      }
    }
    close($t->filehandle());
    return ($ttyrec, $prev_frame, undef, '');
  }
  # If we get here, ouch.
  (undef, undef, undef, undef)
}

1
