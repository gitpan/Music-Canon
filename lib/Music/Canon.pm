# -*- Perl -*-
#
# Routines for musical canon construction. See also C<canonical> of
# the L<App::MusicTools> module for a command line tool interface to
# this code.

package Music::Canon;

use 5.010000;
use strict;
use warnings;

use Carp qw/croak/;
use List::Util qw/sum/;

use Music::AtonalUtil   ();    # Forte Number to interval sets
use Music::LilyPondUtil ();    # transpose convenience
use Music::Scales qw/get_scale_nums is_scale/;
use Scalar::Util qw/blessed looks_like_number/;
use Try::Tiny;

our $VERSION = '0.53';

# NOTE a new() param, below, but I have not thought about what changing
# it would actually do. Use the $self entry in all subsequent code.
my $DEG_IN_SCALE = 12;

my $FORTE_NUMBER_RE = qr/[3-9]-[zZ]?\d{1,2}/;

########################################################################
#
# SUBROUTINES

# one-to-one interval mapping, though with the contrary, retrograde, and
# transpose parameters as possible influences on the results.
sub exact_map {
  my $self = shift;

  my @new_phrase;
  for my $e ( ref $_[0] eq 'ARRAY' ? @{ $_[0] } : @_ ) {
    my $pitch;
    if ( !defined $e ) {
      # presumably rests/silent bits
      push @new_phrase, undef;
      next;
    } elsif ( blessed $e and $e->can('pitch') ) {
      $pitch = $e->pitch;
    } elsif ( looks_like_number $e) {
      $pitch = $e;
    } else {
      # pass through unknowns
      push @new_phrase, $e;
      next;
    }

    my $new_pitch;
    if ( !defined $self->{_exact}->{prev_output} ) {
      my $trans;
      if ( !looks_like_number( $self->{_transpose} ) ) {
        try {
          $trans =
            $self->{_lyu}->notes2pitches( $self->{_transpose} ) - $pitch;
        }
        catch {
          croak $_;
        };
      } else {
        $trans = $self->{_transpose};
      }
      $new_pitch = $pitch + $trans;
    } else {
      my $delta = $pitch - $self->{_exact}->{prev_input};
      $delta *= -1 if $self->{_contrary};
      $new_pitch = $self->{_exact}->{prev_output} + $delta;
    }
    push @new_phrase, $new_pitch;
    $self->{_exact}->{prev_input}  = $pitch;
    $self->{_exact}->{prev_output} = $new_pitch;
  }

  if ( @new_phrase > 1 and $self->{_retrograde} ) {
    @new_phrase = reverse @new_phrase;
  }

  if ( !$self->{_keep_state} ) {
    $self->{_exact} = ();
  }

  return @new_phrase == 1 ? $new_phrase[0] : @new_phrase;
}

sub exact_map_reset {
  my ($self) = @_;
  $self->{_exact} = ();
  return $self;
}

sub get_contrary { $_[0]->{_contrary} }

sub get_modal_chrome {
  my ($self) = @_;
  return $self->{_chrome_weight} // 0;
}

sub get_modal_pitches {
  my ($self) = @_;
  return $self->{_modal}->{input_tonic}, $self->{_modal}->{output_tonic};
}

sub get_retrograde { $_[0]->{_retrograde} }

sub get_scale_intervals {
  my ( $self, $layer ) = @_;
  if ( !defined $layer or ( $layer ne 'input' and $layer ne 'output' ) ) {
    croak "unsupported layer (must be 'input' or 'output')";
  }
  # internally ASC, DSC scale intervals both up from tonic, but for
  # users DSC scales are done from tonic downwards
  return $self->{$layer}->{1}, [ reverse @{ $self->{$layer}->{-1} } ];
}

sub get_transpose {
  my ($self) = @_;
  if ( !exists $self->{_transpose}
    or !defined $self->{_transpose} ) {
    $self->{_transpose} = 0;
  }
  return $self->{_transpose};
}

# Modal interval mapping - determines the number of diatonic steps and
# chromatic offset (if any) from the direction and magnitude of the
# delta from the previous input pitch via the input scale intervals,
# then replays that number of diatonic steps and (if possible) chromatic
# offset via the output scale intervals. Ascending vs. descending motion
# may be handled by different scale intervals, if a melodic minor or
# similar asymmetric interval set is involved. If this sounds tricky and
# complicated, it is because it is.
sub modal_map {
  my $self = shift;

  my @new_phrase;
  my $obj_index = 0;
  for my $obj ( ref $_[0] eq 'ARRAY' ? @{ $_[0] } : @_ ) {
    my $pitch;
    if ( !defined $obj ) {
      # presumably rests/silent bits
      push @new_phrase, undef;
      next;
    } elsif ( blessed $obj and $obj->can('pitch') ) {
      $pitch = $obj->pitch;
    } elsif ( looks_like_number $obj) {
      $pitch = $obj;
    } else {
      # pass through unknowns
      push @new_phrase, $obj;
      next;
    }

    # Interval sets are useless without being tied to some pitch, derive
    # from input phrase if unset (the set_modal_pitches() method can
    # customize these in advance if necessary)
    $self->{_modal}->{input_tonic} = $pitch
      unless defined $self->{_modal}->{input_tonic};

    # Output tonic set based on transposed pitch, as might be mapping c'
    # to c'' via transpose of 12 in which case want MIDI 60 for the
    # input tonic and then MIDI 72 for the output tonic.
    my $trans = 0;
    if ( !looks_like_number( $self->{_transpose} ) ) {
      try {
        $trans = $self->{_lyu}->notes2pitches( $self->{_transpose} ) - $pitch;
      }
      catch {
        croak $_;
      };
    } else {
      $trans = $self->{_transpose};
    }
    $self->{_modal}->{output_tonic} = $self->{_modal}->{input_tonic} + $trans
      unless defined $self->{_modal}->{output_tonic};

    my $new_pitch;
    if ( defined $self->{_modal}->{input_prev_pitch}
      and $self->{_modal}->{input_prev_pitch} == $pitch ) {
      # oblique motion optimization (a repeated note): just copy previous
      $new_pitch = $self->{_modal}->{output_prev_pitch};

    } else {
      # Figure out whether input should be figured on the ascending or
      # descending scale intervals (descending intervals only if there
      # is a previous pitch and if the delta from that previous pitch
      # shows descending motion).
      my $input_motion = 1;
      if ( defined $self->{_modal}->{input_prev_pitch} ) {
        my $pp_delta = $pitch - $self->{_modal}->{input_prev_pitch};
        $input_motion = -1 if $pp_delta < 0;
      }
      my $output_motion =
        $self->{_contrary} ? $input_motion * -1 : $input_motion;

      # Magnitude of interval from tonic, and whether above or below the
      # tonic (as if below, must walk scale intervals backwards).
      my $input_tonic_delta = $pitch - $self->{_modal}->{input_tonic};
      my $is_dsc = $input_tonic_delta < 0 ? 1 : 0;
      $input_tonic_delta = abs $input_tonic_delta;

      # Determine the number of diatonic steps from the tonic to the
      # (possibly transposed) pitch, plus chromatic leftovers (if any).
      my $running_total = 0;
      my $steps         = 0;
      my $input_idx     = 0;
      while ( $running_total < $input_tonic_delta ) {
        $input_idx = $steps++ % @{ $self->{input}->{$input_motion} };
        $input_idx = $#{ $self->{input}->{$input_motion} } - $input_idx
          if $is_dsc;
        $running_total += $self->{input}->{$input_motion}->[$input_idx];
      }
      my $last_input_interval = $self->{input}->{$input_motion}->[$input_idx];
      my $chromatic_offset    = $running_total - $input_tonic_delta;

      # Contrary motion means not only the opposite scale intervals,
      # but the opposite direction through those intervals (in
      # melodic minor, ascending motion in ascending intervals (C to
      # Eflat) corresponds to descending motion in descending
      # intervals (C to Aflat).
      $is_dsc = $is_dsc ? 0 : 1 if $self->{_contrary};

      # Replay the same number of diatonic steps using the appropriate
      # output intervals and direction of interval iteration, plus
      # chromatic adjustments, if any.
      my $output_interval = 0;
      my $idx;
      if ($steps) {
        # steps is incremented past where we need to be, so back off by one
        $steps--;
        for my $s ( 0 .. $steps ) {
          $idx = $s % @{ $self->{output}->{$output_motion} };
          $idx = $#{ $self->{output}->{$output_motion} } - $idx if $is_dsc;
          $output_interval += $self->{output}->{$output_motion}->[$idx];
        }
      }

      if ( $chromatic_offset != 0 ) {
        my $step_interval = $self->{output}->{$output_motion}->[$idx];
        my $step_dir = $step_interval < 0 ? -1 : 1;
        $step_interval = abs $step_interval;

        if ( $chromatic_offset >= $step_interval ) {
          # NOTE thought about doing a hook function here, but that
          # would require tricky code to integrate properly with both
          # the $new_pitch and @new_phrase assignments, below. So just
          # blow up and let caller handle things. (Probably via note-by-
          # note calls into this routine, as otherwise who knows what
          # note the conversion blew up on.)
          croak "undefined chromatic conversion at index $obj_index";
        } else {
          if ( $step_interval == 2 ) {
            # only one possible chromatic fits
            $output_interval -= $step_dir * $chromatic_offset;
          } else {
            # _chrome_weight is a troolean - either a literal chromatic
            # going up or down if positive or negative, otherwise if 0
            # try to figure out something proportional to where the
            # chromatic was between the diatonics of the input scale.
            if ( $self->{_chrome_weight} > 0 ) {
              $output_interval -= $step_dir * $chromatic_offset;
            } elsif ( $self->{_chrome_weight} < 0 ) {
              $output_interval +=
                $step_dir * ( $chromatic_offset - $step_interval );
            } else {
              my $fraction = sprintf "%.0f",
                $step_interval * $chromatic_offset / $last_input_interval;
              $output_interval += $step_dir * ( $fraction - $step_interval );
            }
          }
        }
      }

      $output_interval = int( $output_interval * -1 ) if $is_dsc;
      $new_pitch = $self->{_modal}->{output_tonic} + $output_interval;
    }

    push @new_phrase, $new_pitch;
    $self->{_modal}->{input_prev_pitch}  = $pitch;
    $self->{_modal}->{output_prev_pitch} = $new_pitch;

    $obj_index++;
  }

  # Flip phrase and tidy up state if required. NOTE this must be done
  # manually by the caller if this method is being called note-by-note--
  # perldoc has example code.
  if ( @new_phrase > 1 and $self->{_retrograde} ) {
    @new_phrase = reverse @new_phrase;
  }

  if ( !$self->{_keep_state} ) {
    my ( $it, $ot ) = @{ $self->{_modal} }{qw/input_tonic output_tonic/};
    $self->{_modal} = ();
    @{ $self->{_modal} }{qw/input_tonic output_tonic/} = ( $it, $ot );
  }

  return @new_phrase == 1 ? $new_phrase[0] : @new_phrase;
}

sub modal_map_reset {
  my ($self) = @_;
  my ( $it, $ot ) = @{ $self->{_modal} }{qw/input_tonic output_tonic/};
  $self->{_modal} = ();
  @{ $self->{_modal} }{qw/input_tonic output_tonic/} = ( $it, $ot );
  return $self;
}

sub new {
  my ( $class, %param ) = @_;
  my $self = {};

  $self->{_atu} =
    exists $param{atu}
    ? $param{atu}
    : Music::AtonalUtil->new;

  $self->{_chrome_weight} =
    exists $param{chrome_weight} ? $param{chrome_weight} <=> 0 : 0;

  $self->{_contrary} = exists $param{contrary} ? $param{contrary} ? 1 : 0 : 1;

  $self->{_DEG_IN_SCALE} = int( $param{DEG_IN_SCALE} // $DEG_IN_SCALE );
  if ( $self->{_DEG_IN_SCALE} < 2 ) {
    croak "degrees in scale must be greater than one";
  }

  $self->{_lyu} =
    exists $param{lyu}
    ? $param{lyu}
    : Music::LilyPondUtil->new( mode => 'absolute' );

  $self->{_keep_state} =
    exists $param{keep_state} ? $param{keep_state} ? 1 : 0 : 1;
  $self->{_non_octave_scales} = $param{non_octave_scales} // 0;
  $self->{_retrograde} =
    exists $param{retrograde} ? $param{retrograde} ? 1 : 0 : 1;
  $self->{_transpose} = $param{transpose} // 0;

  bless $self, $class;

  try {
    # XXX there is no way to set the descending mode via this interface,
    # think about how to do that here.
    if ( exists $param{input} ) {
      $self->set_scale_intervals( 'input', $param{input} );
    }
    if ( exists $param{output} ) {
      $self->set_scale_intervals( 'output', $param{output} );
    }

    # otherwise default to major/major conversion
    if ( !exists $self->{input} ) {
      $self->set_scale_intervals( 'input', 'major' );
    }
    if ( !exists $self->{output} ) {
      $self->set_scale_intervals( 'output', 'major' );
    }
  }
  catch {
    croak $_;
  };

  return $self;
}

sub reset_modal_pitches {
  my ($self) = @_;
  undef $self->{_modal}->{input_tonic};
  undef $self->{_modal}->{output_tonic};
  return $self;
}

sub set_contrary {
  my ( $self, $contrary ) = @_;
  $self->{_contrary} = $contrary ? 1 : 0;
  return $self;
}

sub set_retrograde {
  my ( $self, $retrograde ) = @_;
  $self->{_retrograde} = $retrograde ? 1 : 0;
  return $self;
}

sub set_modal_chrome {
  my ( $self, $weight ) = @_;
  $weight //= 0;
  $self->{_chrome_weight} = $weight <=> 0;
  return $self;
}

sub set_modal_pitches {
  my ( $self, $input_pitch, $output_pitch ) = @_;

  try {
    if ( defined $input_pitch ) {
      $self->{_modal}->{input_tonic} =
        $self->{_lyu}->notes2pitches($input_pitch);
      # reset output if something prior there so not carrying along
      # something from a previous conversion
      if ( defined $self->{_modal}->{output_tonic}
        and !defined $output_pitch ) {
        undef $self->{_modal}->{output_tonic};
      }
    }
    if ( defined $output_pitch ) {
      $self->{_modal}->{output_tonic} =
        $self->{_lyu}->notes2pitches($output_pitch);
    }
  }
  catch {
    croak $_;
  };

  return $self;
}

sub set_scale_intervals {
  my ( $self, $layer, $asc, $dsc ) = @_;

  if ( !defined $layer or ( $layer ne 'input' and $layer ne 'output' ) ) {
    croak "unsupported layer (must be 'input' or 'output')";
  }
  if ( !defined $asc and !defined $dsc ) {
    croak "must define one of asc or dsc or both";
  }

  my $is_scale = 0;
  if ( defined $asc ) {

    if ( ref $asc eq 'ARRAY' ) {
      # Assume arbitrary list of intervals as integers if array ref
      for my $n (@$asc) {
        croak "ascending intervals must be integers"
          unless looks_like_number $n and $n =~ m/^[+-]?\d+$/;
      }
      $self->{$layer}->{1} = $asc;

    } elsif ( $asc =~ m/($FORTE_NUMBER_RE)/ ) {
      # derive scale intervals from pitches of the named Forte Number
      my $pset = $self->{_atu}->forte2pcs($1);
      croak "no such Forte Number for ascending" unless defined $pset;

      $self->{$layer}->{1} = $self->{_atu}->pcs2intervals($pset);

    } else {
      # derive intervals via scale name via third-party module
      croak "ascending scale unknown to Music::Scales"
        unless is_scale($asc);
      my @asc_nums = get_scale_nums($asc);
      my @dsc_nums;
      @dsc_nums = get_scale_nums( $asc, 1 ) unless defined $dsc;

      $self->{$layer}->{1} = [];
      for my $i ( 1 .. $#asc_nums ) {
        push @{ $self->{$layer}->{1} }, $asc_nums[$i] - $asc_nums[ $i - 1 ];
      }
      if (@dsc_nums) {
        $self->{$layer}->{-1} = [];
        for my $i ( 1 .. $#dsc_nums ) {
          unshift @{ $self->{$layer}->{-1} },
            $dsc_nums[ $i - 1 ] - $dsc_nums[$i];
        }
      }
      $is_scale = 1;
    }
  }

  if ( !defined $dsc ) {
    # Assume descending equals ascending (true in most cases, except
    # melodic minor and similar), unless a scale was involved, as the
    # Music::Scales code should already have setup the descending bit.
    $self->{$layer}->{-1} = $self->{$layer}->{1}
      unless $is_scale;
  } else {
    if ( ref $dsc eq 'ARRAY' ) {
      for my $n (@$dsc) {
        croak "descending intervals must be integers"
          unless looks_like_number $n and $n =~ m/^[+-]?\d+$/;
      }
      $self->{$layer}->{-1} = [ reverse @$dsc ];

    } elsif ( $dsc =~ m/($FORTE_NUMBER_RE)/ ) {
      # derive scale intervals from pitches of the named Forte Number
      my $pset = $self->{_atu}->forte2pcs($1);
      croak "no such Forte Number for descending" unless defined $pset;

      $self->{$layer}->{-1} = $self->{_atu}->pcs2intervals($pset);

    } else {
      croak "descending scale unknown to Music::Scales"
        unless is_scale($dsc);
      my @dsc_nums = get_scale_nums( $dsc, 1 );

      $self->{$layer}->{-1} = [];
      for my $i ( 1 .. $#dsc_nums ) {
        unshift @{ $self->{$layer}->{-1} },
          $dsc_nums[ $i - 1 ] - $dsc_nums[$i];
      }
    }
  }

  # Complete scales to sum to 12 by default (Music::Scales omits the VII
  # to I interval, and who knows what a custom list would contain).
  if ( !$self->{_non_octave_scales} ) {
    for my $ref ( $self->{$layer}->{1}, $self->{$layer}->{-1} ) {
      my $sum = sum @$ref;
      if ( $sum < $self->{_DEG_IN_SCALE} ) {
        push @$ref, $self->{_DEG_IN_SCALE} - $sum;
      } elsif ( $sum > $self->{_DEG_IN_SCALE} ) {
        croak "non-octave scales require non_octave_scales param";
      }
    }
  }

  return $self;
}

sub set_transpose {
  my ( $self, $transpose ) = @_;
  $self->{_transpose} = $transpose // 0;
  return $self;
}

1;
__END__

=head1 NAME

Music::Canon - routines for musical canon construction

=head1 SYNOPSIS

  use Music::Canon ();
  my $mc = Music::Canon->new;

  # options affecting all the *_map routines
  $mc->set_contrary(1);
  $mc->set_retrograde(1);
  $mc->set_transpose(12);     # by semitones
  $mc->set_transpose(q{c'});  # or "to" a lilypond note

  # 1:1 semitone mapping
  my @new_phrase = $mc->exact_map(qw/0 7 4 0 -1 0/);
  $mc->exact_map_reset;

  # trickier is the so-called modal mapping;
  # default is Major to Major
  @new_phrase = $mc->modal_map(qw/0 7 4 0 -1 0/);
  $mc->modal_map_reset;

  # or instead modal mapping by scale name (via Music::Scales)
  $mc->set_scale_intervals( 'input',  'minor'  );
  $mc->set_scale_intervals( 'output', 'dorian' );
  @new_phrase = $mc->modal_map(qw/0 7 4 0 -1 0/);

See also C<canonical> of the L<App::MusicTools> module for a command
line tool interface to this code, and the C<eg/> and C<t/> directories
of this distribution for more example code.

=head1 DESCRIPTION

Musical canons involve horizontal lines of music (often called voices)
that are combined with other canon or free counterpoint voices to
produce harmony. This module assists with the creation of new voices via
C<*_map> methods that transform pitches according to various rules.
Chords could also be transformed via the C<*_map> functions by passing
the pitches of the chord to the C<*_map> method, then forming a new
chord from the results.

Whether the output is usable is left to the composer. Harmony can be
created by careful selection of the input material and the mapping
settings, or perhaps by adding a free counterpoint voice to support the
canon voices. Analyzing the results with L<Music::Tension> may help
search for suitable material.

The methods of this module at present suit crab canon, as those lines
are relatively easy to calculate. Other forms of canon would ideally
require a counterpoint module, which has not yet been written. The
B<modal_map> method also suits the calculation of new voices of a fugue,
for example converting the subject to the dominant.

Knowledge of canon will doubtless help any user of this module; the
L</"SEE ALSO"> section lists resources for learning these.

=head1 METHODS

Methods may B<die> or B<croak> under various conditions. B<new> would be
a good one to start with, then one of the C<*_map> functions to
transform the list of pitches into new material.

Most methods, notably the C<*_map> methods, operate only on pitch
numbers. Some methods also accept lilypond note names (via
L<Music::LilyPondUtil>). Use B<notes2pitches> of L<Music::LilyPondUtil>
to convert notes to pitches suitable for passing to a C<*_map> function.
Otherwise, MIDI pitch numbers could easily be fed to the mapping
methods, or objects that have a B<pitch> method.

=over 4

=item B<exact_map> I<phrase>

One-to-one semitone mapping from the input I<phrase> to the returned
list. I<phrase> may be a list or an array reference, and may contain raw
pitch numbers, objects that support a B<pitch> method, or other data
that will be passed through unchanged.

Affected by various settings, notably B<set_contrary>,
B<set_retrograde>, and B<set_transpose>.

Be sure to call B<exact_map_reset> when done converting a phrase, or
disable the B<keep_state> option of B<new> and then pass the phrase
in a single call to B<exact_map>.

=item B<exact_map_reset>

Resets current state of the B<exact_map> method. Not necessary if
B<keep_state> option of B<new> disabled, and entire phrases passed in
one go to B<exact_map>.

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<get_contrary>

Returns the current contrary setting (boolean).

=item B<get_modal_chrome>

Returns current B<modal_map> chrome weighting (troolean).

=item B<get_modal_pitches>

Returns the current modal input and output layer starting pitches used
by B<modal_map>. These will be undefined if unset, or might have values
leftover from some previous conversion, unless reset via
B<reset_modal_pitches>.

=item B<get_retrograde>

Returns the current retrograde setting (boolean). Retrograde is a fancy
way to indicate that the output list be reversed.

=item B<get_scale_intervals> I<layer>

Returns the scale intervals for the indicated I<layer> (C<input> or
C<output>), or throws an exception if these are unset. The intervals are
returned as a list of two array references, the first for the scale
ascending, the second for the scale descending.

Note that descending scale intervals are noted from the highest note down.

=item B<get_transpose>

Returns the current transpose setting (integer of semitones or lilypond
note name, depending on what was previously set).

=item B<modal_map> I<phrase>

Modal mapping of the pitches in I<phrase> from an arbitrary input mode
to an arbitrary output mode, as set by B<set_scale_intervals>, or the
Major to Major scales by default. Returns a list, or throws an exception
if a pitch cannot be converted. I<phrase> may be a list or an array
reference, and may contain raw pitch numbers, objects that support a
B<pitch> method, or other data that will be passed through unchanged.

Configuring the starting pitches via B<set_modal_pitches> is a necessity
if the I<phrase> starts on a scale degree that is not the root or tonic
of the mode involved. That is, a I<phrase> that begins on the note E
will create a mapping around E-major by default; if a mapping around C-
Major (at MIDI pitch 60) is intended, this must be set in advance:

  # by pitch number
  $mc->set_modal_pitches( 60, 60 );
  $mc->modal_map(qw/64 .../);

  # or the equivalent via lilypond note names
  $mc->set_modal_pitches(qw/c' c'/);
  $mc->modal_map(qw/e' .../);

NOTE B<modal_map> is somewhat experimental, so likely has edge cases or
bugs unknown to me, or may change without notice as I puzzle through the
mapping logic. Consult the tests under the module distribution C<t/>
directory for what cases are covered. It is also relatively unexplored,
for example mapping between exotic scales or Forte Numbers.

The algorithm operates by converting the intervals between the notes
into diatonic steps via the input mode, then replicates that many steps
in the output mode, followed by any necessary chromatic adjustments. The
initial starting pitches (derived from the input phrase and transpose
setting, or via pitches set via the B<set_modal_pitches> method) form
the point of linkage between the two scales or really any arbitrary
interval sequences.

Transposition (via B<set_transpose>) will influence the output linking
pitch, unless that value was already set via a prior conversion or
B<set_modal_pitches> call.

An example may help illustrate this function. Assuming Major to
Major conversion, contrary motion, and a transposition by an octave
(12 semitones), the software will convert pitches as shown in this
chart (the "linking point" is from 0 in the input scale to 12 in the
output scale):

        0    1    2   3    4   5   6    7   8    9   10  11  12
  In  | C  | c# | D | d# | E | F | f# | G | g# | A | a# | B | C' |
  Out | C' | x  | B | a# | A | G | f# | F | x  | E | d# | D | C  |
       12        11   10   9   7   6    5        4   3    2   0

Assuming an input phrase of C<C G c#>, the output phrase would be C<C'
F> and then an exception would be thrown, as there is no way to convert
C<c#> using this modal mapping and transposition. Other mappings and
transpositions will have between zero to several notes that cannot be
converted. The C<eg/conversion-charts> file of this module's distribution
contains more such charts, as also can be generated by the
C<eg/brutecanon> utility.

How to map non-diatonic notes is another concern; the above chart shows
two C<x> for notes that cannot be converted. Depending on the mapping,
there might be zero, one, or several possible choices for a given
chromatic. Consider C<c#> of C Major to various entry points of the
sakura scale C<G# A# B D# E>:

    C Major    | C  | c# | D  | 
  ------------------------------------------------------------
  Sakura @ G#  | G# | a  | A# |  - one choice
  Sakura @ A#  | A# | x  | B  |  - throw exception
  Sakura @ B   | B  | ?  | D# |  - (c, c#, d)

The I<chrome_weight> parameter to B<new> controls the multiple choice
situation. The default setting of C<0> results in C<c#>, as that value
is halfway between C<B> and C<D>, just as the input scale chromatic is
halfway between C<C> and C<D>. Otherwise, with a negative
I<chrome_weight>, C<c> is favored, or for a positive I<chrome_weight>,
C<d>. Test cases are advised to confirm that the resulting chromatics
are appropriate, though this should only be necessary if the output
scale has intervals greater than two (e.g. hungarian minor, or any of
the pentatonic scales, etc).

B<modal_map> is affected by various settings, notably B<set_contrary>,
B<set_modal_pitches>, B<set_retrograde>, B<set_scale_intervals>, and
B<set_transpose>.

Be sure to call B<modal_map_reset> when done converting a phrase.
B<reset_modal_pitches> may also be necessary to clear prior scale
linking points.

=item B<modal_map_reset>

Resets the state variables associated with B<modal_map>, with the
exception of the pitches set by the B<set_modal_pitches> call (or
automatically from the input phrase), which are not reset by this method
(use the B<reset_modal_pitches> method to accomplish that).

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<new>

Constructor. Accepts a number of options, the useful or safe of which
are listed here.

=over 4

=item *

I<chrome_weight> - sets the B<chrome_weight> troolean. Zero by default.

I<chrome_weight> controls how chromatics between output intervals
greater than two semitones are handled in B<modal_map>; if this
parameter is negative, the literal chromatic step from the input scale
will be used from the previous pitch (bottom up), if positive the
literal chromatic step will be applied in the other direction (top
down), and if zero (the default) a value proportionally closest to where
the chromatic is in the input interval will be calculated. See
documentation for B<modal_map> for a longer example.

=item *

I<contrary> - sets the B<contrary> boolean. On by default.

=item *

I<input> - scale or Forte Number or interval set for the B<modal_map>
input mode. Defaults to the Major scale if unset. See
B<set_scale_intervals> and B<modal_map> for details.

=item *

I<keep_state> - configures whether state is maintained through different
calls to the various C<*_map> methods. On by default, which requires the
use of the corresponding C<*_map_reset> method when a phrase is
complete. There are two possible workflows; with state enabled, multiple
calls can be made to the mapping function, which suits B<modal_map>:

  use Try::Tiny;

  my $mc_state = Music::Canon->new;
  for my $e (@input) {
    my $result;
    try { $result = $mc_state->modal_map($e) }
    catch {
      if (m/undefined chromatic conversion/) {
        $result = 'r';   # make it a lilypond rest
      } else {
        ...              # handle error as appropriate
      }
    };
    push @output, $result;
  }
  @output = reverse @output if $mc->get_retrograde;
  $mc_state->modal_map_reset;

The other workflow is to disable state, and pass entire phrases for
conversion in one call. This better suits B<exact_map>, which unlike the
modal transformation will not have pitches it cannot convert, and thus
will not need to handle individual note exceptions:

  my $mc_no_state = Music::Canon->new(keep_state => 0);
  my @output = $mc_no_state->exact_map(\@input);

=item *

I<non_octave_scales> - configures whether scales should be bounded at an
octave (12 semitones) or not. The default is to pad interval sets that
sum up to less than 12 to include an additional element such that the
sum of the intervals is 12. Interval sets greater than 12 will cause an
exception to be thrown.

Enable this option only if dealing with a maqam or similar scale that is
not bounded by the Western notion of octave. For example, the whole tone
scale (which is really just an expensive way to do an B<exact_map>):

  my $mc = Music::Canon->new( non_octave_scales => 1 );
  # or Forte Number '6-35'
  $mc->set_scale_intervals('input',  [2,2,2,2,2] );
  $mc->set_scale_intervals('output', [2,2,2,2,2] );

=item *

I<output> - scale or Forte Number or interval set for the B<modal_map>
output mode. Defaults to the Major scale if unset. See
B<set_scale_intervals> and B<modal_map> for details.

=item *

I<retrograde> - sets whether phrases are reversed. On by default.

=item *

I<transpose> - value to transpose by, in semitones, or "to" a lilypond
note name.

=back

=item B<reset_modal_pitches>

Routine to nullify the B<modal_map> pitches that are either set by the
first note of the input phrase, or via the B<set_modal_pitches> method.
These values otherwise persist across calls to B<modal_map>.

=item B<set_contrary> I<boolean>

Sets the contrary boolean (on by default). With this set, phrases
from the C<*_map> routines will be set in contrary motion to the
input phrase.

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_modal_chrome> I<weight>

Sets the B<modal_map> chrome weighting. Troolean: 0 (proportional),
negative (literal from previous note up), or positive (literal from
current note down).

=item B<set_modal_pitches> I<input_tonic>, [ I<output_tonic> ]

Sets the tonic note or pitch of the input and output interval sets used
by B<modal_map>. If the I<input_tonic> is set, but not the optional
I<output_tonic>, the cached I<output_tonic> value, if any, will be
wiped out.

  $mc->set_modal_pitches(60, 62);
  $mc->set_modal_pitches(undef, 64);  # just output start pitch
  $mc->set_modal_pitches(q{c'});      # by lilypond note

Using this method is a necessity if the I<phrase> passed to
B<modal_map> begins on a non-tonic scale degree, as otherwise that non-
tonic scale degree will become the tonic for whatever interval set is
involved. That is, if the notes C<e e f g g> are passed to
B<modal_map>, by default B<modal_map> will assume C<e> Major as the
input scale, and C<e> Major as the output scale (though that may vary
depending on the B<transpose> setting).

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_retrograde> I<boolean>

Sets the retrograde boolean (on by default). If set, phrases from the
C<*_map> routines will be reversed. Meaningless if C<*_map> calls are
being made note-by-note (see the I<keep_state> documentation).

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_scale_intervals> I<layer>, I<asc>, [I<dsc>]

Sets the scale intervals for the indicated I<layer> (C<input> or
C<output>). The I<asc> (and optional I<dsc>) can be one of several
different things:

  $mc->set_scale_intervals('input', 'minor');  # Music::Scales
  $mc->set_scale_intervals('input', '7-23');   # Forte Number
  # arbitrary interval sequence
  $mc->set_scale_intervals('input', [qw/2 1 3 2 1 3 1/]);

If the I<dsc> is undefined, the corresponding I<asc> intervals will be
used, except for L<Music::Scales>, for which the descending intervals
associated with the ascending scale will be used. If I<asc> is
undefined, I<dsc> must then be set to something. This allows the
descending intervals alone to be adjusted.

  $mc->set_scale_intervals('output', undef, 'aeolian');

Note that the descending intervals must be ordered from the highest
pitch down. That is, melodic minor can be stated manually via:

  $mc->set_scale_intervals( 'output',
    [2,1,2,2,2,2],  # ascending  - c d ees f g a b
    [2,2,1,2,2,1]   # descending - c bes aes g f ees d
  );

Though this particular case would be much more easily stated via
L<Music::Scales> via:

  $mc->set_scale_intervals('output', 'mm');

B<set_scale_intervals> returns the L<Music::Canon> object, so can be
chained with other method calls.

=item B<set_transpose> I<integer or lilypond note>

Sets the value to transpose to or by in C<*_map> methods, either in
semitones, or to a particular lilypond note:

  $mc->set_transpose(-12)    # down by an octave
  $mc->set_transpose(q{c'})  # to the lilypond note

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=back

=head1 SEE ALSO

"Counterpoint in Composition" by Felix Salzer and Carl Schachter.

"The Technique of Canon" by Hugo Norden

"Counterpointer" by Ars Nova (counterpoint instruction software).

L<http://en.wikipedia.org/wiki/Forte_number>

L<Music::AtonalUtil>, L<Music::LilyPondUtil>, L<Music::Scales>,
L<Music::Tension>

The C<canonical> and C<scalemogrifier> utilities of L<App::MusicTools>
may also be of interest.

=head1 AUTHOR

Jeremy Mates, E<lt>jmates@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Jeremy Mates

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.16 or, at
your option, any later version of Perl 5 you may have available.

=cut
