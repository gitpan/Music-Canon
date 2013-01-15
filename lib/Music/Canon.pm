# -*- Perl -*-
#
# routines for musical canon construction

package Music::Canon;

use 5.010000;
use strict;
use warnings;

use Carp qw(croak);
use List::Util qw/sum/;

use Music::AtonalUtil   ();    # Forte Number to interval sets
use Music::LilyPondUtil ();    # transpose convenience
use Music::Scales qw/get_scale_nums is_scale/;
use Scalar::Util qw/blessed looks_like_number/;

our $VERSION = '0.12';

# NOTE a new() param, below, but I have not thought about what changing
# it would actually do. Use the $self entry in all subsequent code.
my $DEG_IN_SCALE = 12;

my $FORTE_NUMBER_RE = qr/[3-9]-[zZ]?\d{1,2}/;

########################################################################
#
# SUBROUTINES

# 1:1 interval mapping, though with the contrary, retrograde, and
#   transpose parameters as possible influences on the results.
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
        eval {
          $trans =
            $self->{_lyu}->notes2pitches( $self->{_transpose} ) - $pitch;
        };
        croak $@ if $@;
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

  @new_phrase = reverse @new_phrase if $self->{_retrograde};

  if ( !$self->{_keep_state} ) {
    undef $self->{_exact}->{prev_input};
    undef $self->{_exact}->{prev_output};
  }

  return @new_phrase;
}

sub exact_map_reset {
  my ($self) = @_;
  undef $self->{_exact}->{prev_input};
  undef $self->{_exact}->{prev_output};
  return $self;
}

sub get_contrary { $_[0]->{_contrary} }

sub get_modal_pitches {
  my ($self) = @_;

  return $self->{_modal}->{input_start_pitch},
    $self->{_modal}->{output_start_pitch};
}

sub get_retrograde { $_[0]->{_retrograde} }

sub get_scale_intervals {
  my ( $self, $layer ) = @_;
  if ( !defined $layer or ( $layer ne 'input' and $layer ne 'output' ) ) {
    croak "unsupported layer (must be 'input' or 'output')\n";
  }
  if ( !exists $self->{$layer}->{1}->{intervals}
    or !exists $self->{$layer}->{-1}->{intervals} ) {
    croak "scale intervals for $layer not previously set\n";
  }
  return $self->{$layer}->{1}->{intervals},
    $self->{$layer}->{-1}->{intervals};
}

sub get_transpose {
  my ($self) = @_;
  if ( !exists $self->{_transpose}
    or !defined $self->{_transpose} ) {
    $self->{_transpose} = 0;
  }
  return $self->{_transpose};
}

# Modal interval mapping, where steps taken will vary depending on the
# input and output modes (a.k.a scales or really just arbitrary lists of
# intervals), where in those modes the notes lie, the starting notes,
# and also the various contrary, retrograde, and transpose parameters.
sub modal_map {
  my $self = shift;

  # default to major/major conversion
  if ( !exists $self->{input} ) {
    $self->scale_intervals( 'input', 'major' );
  }
  if ( !exists $self->{output} ) {
    $self->scale_intervals( 'output', 'major' );
  }

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

    $self->{_modal}->{input_start_pitch} = $pitch
      unless defined $self->{_modal}->{input_start_pitch};

    my $new_pitch;
    if ( !defined $self->{_modal}->{output_start_pitch} ) {
      # copy at transpose offset if nothing prior, set things up for the
      # subsequent calculations, which are all done relative to this
      # known linking point between the two different modes.
      my $trans;
      if ( !looks_like_number( $self->{_transpose} ) ) {
        eval {
          $trans =
            $self->{_lyu}->notes2pitches( $self->{_transpose} ) - $pitch;
        };
        croak $@ if $@;
      } else {
        $trans = $self->{_transpose};
      }
      $new_pitch = $pitch + $trans;
      $self->{_modal}->{output_start_pitch} = $new_pitch;

    } else {
      # modal mapping - diatonic where possible, chromatic or undefined
      # otherwise. Gist of the logic is to figure out how many diatonic
      # steps (or substeps for chromaics) there are via the input mode,
      # then replay that may number of steps (or substeps for
      # chromatics, if possible) in the appropriate output mode, as
      # modified by the contrary and transpose parameters.

      my %input;
      $input{delta} = $pitch - $self->{_modal}->{input_start_pitch};
      my $dir = $input{delta} < 0 ? -1 : 1;

      $input{cycles} =
        int abs( $input{delta} ) / $self->{input}->{$dir}->{sum};
      $input{remainder} =
        abs( $input{delta} ) % $self->{input}->{$dir}->{sum};

      my $steps            = $input{cycles} * $self->{input}->{$dir}->{sum};
      my $running_total    = 0;
      my $chromatic_offset = 0;
      for my $step ( @{ $self->{input}->{$dir}->{intervals} } ) {
        $running_total += $step;
        $steps++;
        if ( $running_total >= $input{remainder} ) {
          $chromatic_offset = $running_total - $input{remainder};
          last;
        }
      }

      # dbg input audit
      #use Data::Dumper; warn Dumper \%input, $steps;

      my %output;
      $dir *= -1 if $self->{_contrary};

      # dbg direction seemed fine

      # so now from steps back to an interval and direction, and from those a
      # new pitch for the new phrase. Will be N many steps, and if not
      # chromatic, we're done, as diatonic will always map to something.
      $output{cycles} =
        int $steps / @{ $self->{output}->{$dir}->{intervals} };
      $output{remainder} =
        $steps % @{ $self->{output}->{$dir}->{intervals} };

      # dbg steps look find in output...
      #use Data::Dumper; warn Dumper \%output, $dir;

      my ( @slice, $step_index );
      if ( $dir < 0 ) {
        $step_index =
          $#{ $self->{output}->{$dir}->{intervals} } - $output{remainder} + 1;
        @slice = $step_index .. $#{ $self->{output}->{$dir}->{intervals} };
      } else {
        $step_index = $output{remainder} - 1;
        @slice      = 0 .. $step_index;
      }

      my $interval = $self->{output}->{$dir}->{sum} * $output{cycles} +
        sum @{ $self->{output}->{$dir}->{intervals} }[@slice];

      if ($chromatic_offset) {
        my $step_interval =
          $self->{output}->{$dir}->{intervals}->[$step_index];
        if ( $chromatic_offset >= $step_interval ) {
          # NOTE thought about doing a hook function here, but that
          # would require tricky code to integrate properly with both
          # the $new_pitch and @new_phrase assignments, below. So just
          # blow up and let caller handle things. (Probably via note-by-
          # note calls into this routine, as otherwise who knows what
          # note the conversion blew up on.)
          croak "undefined chromatic conversion at index $obj_index\n";
        } else {
          $interval -= $chromatic_offset;
        }
      }

      $interval *= $dir;
      $new_pitch = $self->{_modal}->{output_start_pitch} + $interval;
    }

    push @new_phrase, $new_pitch;
    $obj_index++;
  }

  # flip phrase and tidy up state if required
  @new_phrase = reverse @new_phrase if $self->{_retrograde};

  if ( !$self->{_keep_state} ) {
    undef $self->{_modal}->{input_start_pitch};
    undef $self->{_modal}->{output_start_pitch};
  }

  return @new_phrase;
}

sub modal_map_reset {
  my ($self) = @_;
  undef $self->{_modal}->{input_start_pitch};
  undef $self->{_modal}->{output_start_pitch};
  return $self;
}

sub new {
  my ( $class, %param ) = @_;
  my $self = {};

  $self->{_atu} =
    exists $param{atu}
    ? $param{atu}
    : Music::AtonalUtil->new;

  $self->{_contrary} = exists $param{contrary} ? $param{contrary} ? 1 : 0 : 1;

  $self->{_DEG_IN_SCALE} = int( $param{DEG_IN_SCALE} // $DEG_IN_SCALE );
  if ( $self->{_DEG_IN_SCALE} < 2 ) {
    croak("degrees in scale must be greater than one");
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

  eval {
    if ( exists $param{input} ) {
      $self->set_scale_intervals( 'input', $param{input} );
    }
    if ( exists $param{output} ) {
      $self->set_scale_intervals( 'output', $param{output} );
    }
  };
  croak $@ if $@;

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

sub set_modal_pitches {
  my ( $self, $input_pitch, $output_pitch ) = @_;

  eval {
    if ( defined $input_pitch ) {
      $self->{_modal}->{input_start_pitch} =
        $self->{_lyu}->notes2pitches($input_pitch);
    }
    if ( defined $output_pitch ) {
      $self->{_modal}->{output_start_pitch} =
        $self->{_lyu}->notes2pitches($output_pitch);
    }
  };
  croak $@ if $@;

  return $self;
}

sub set_scale_intervals {
  my ( $self, $layer, $asc, $dsc ) = @_;

  if ( !defined $layer or ( $layer ne 'input' and $layer ne 'output' ) ) {
    croak "unsupported layer (must be 'input' or 'output')\n";
  }

  my $is_scale = 0;
  if ( ref $asc eq 'ARRAY' ) {
    # Assume arbitrary list of intervals as integers if array ref
    for my $n (@$asc) {
      croak "ascending intervals must be integers\n"
        unless looks_like_number $n and $n =~ m/^[+-]?\d+$/;
    }
    $self->{$layer}->{1}->{intervals} = $asc;

  } elsif ( $asc =~ m/($FORTE_NUMBER_RE)/ ) {
    # derive scale intervals from pitches of the named Forte Number
    my $pset = $self->{_atu}->forte2pcs($1);
    croak "no such Forte Number" unless defined $pset;

    $self->{$layer}->{1}->{intervals} = $self->{_atu}->pcs2intervals($pset);

  } else {
    # derive intervals via scale name via third-party module
    croak "ascending scale unknown to Music::Scales\n" unless is_scale($asc);
    my @asc_nums = get_scale_nums($asc);
    my @dsc_nums;
    @dsc_nums = get_scale_nums( $asc, 1 ) unless defined $dsc;

    for my $i ( 1 .. $#asc_nums ) {
      push @{ $self->{$layer}->{1}->{intervals} },
        $asc_nums[$i] - $asc_nums[ $i - 1 ];
    }
    if (@dsc_nums) {
      for my $i ( reverse 1 .. $#dsc_nums ) {
        push @{ $self->{$layer}->{-1}->{intervals} },
          $dsc_nums[ $i - 1 ] - $dsc_nums[$i];
      }
    }
    $is_scale = 1;
  }

  if ( !defined $dsc ) {
    # Assume descending equals ascending (true in most cases, except
    # melodic minor and similar), unless a scale was involved, as the
    # Music::Scales code should already have setup the descending bit.
    $self->{$layer}->{-1}->{intervals} = $self->{$layer}->{1}->{intervals}
      unless $is_scale;
  } else {
    if ( ref $dsc eq 'ARRAY' ) {
      for my $n (@$dsc) {
        croak "descending intervals must be integers\n"
          unless looks_like_number $n and $n =~ m/^[+-]?\d+$/;
      }
      $self->{$layer}->{-1}->{intervals} = $dsc;

    } elsif ( $dsc =~ m/($FORTE_NUMBER_RE)/ ) {
      # derive scale intervals from pitches of the named Forte Number
      my $pset = $self->{_atu}->forte2pcs($1);
      croak "no such Forte Number" unless defined $pset;

      $self->{$layer}->{-1}->{intervals} =
        $self->{_atu}->pcs2intervals($pset);

    } else {
      croak "descending scale unknown to Music::Scales\n"
        unless is_scale($dsc);
      my @dsc_nums = get_scale_nums( $dsc, 1 );

      for my $i ( reverse 1 .. $#dsc_nums ) {
        push @{ $self->{$layer}->{-1}->{intervals} },
          $dsc_nums[ $i - 1 ] - $dsc_nums[$i];
      }
    }
  }

  # Complete scales to sum to 12 by default (Music::Scales omits the VII
  # to I interval, and who knows what a custom list would contain).
  if ( !$self->{non_octave_scales} ) {
    for my $ref ( $self->{$layer}->{1}->{intervals},
      $self->{$layer}->{-1}->{intervals} ) {
      my $interval_sum = sum @$ref;
      if ( $interval_sum < $self->{_DEG_IN_SCALE} ) {
        push @$ref, $self->{_DEG_IN_SCALE} - $interval_sum;
      } elsif ( $interval_sum > $self->{_DEG_IN_SCALE} ) {
        croak "non-octave scales require non_octave_scales param\n";
      }
    }
  }
  $self->{$layer}->{1}->{sum} =
    sum @{ $self->{$layer}->{1}->{intervals} };
  $self->{$layer}->{-1}->{sum} =
    sum @{ $self->{$layer}->{-1}->{intervals} };

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

  use Music::Canon;
  my $mc = Music::Canon->new;

  # options affecting all the *_map routines
  $mc->set_contrary(1);
  $mc->set_retrograde(1);
  $mc->set_transpose(12);     # by semitones
  $mc->set_transpose(q{c'});  # or "to" a lilypond note

  # 1:1 semitone mapping
  my @phrase = $mc->exact_map(qw/0 7 4 0 -1 0/);
  $mc->exact_map_reset;

  # trickier is the so-called modal mapping
  # default is Major to Major (or call set_scale_intervals first)
  @phrase = $mc->modal_map(qw/0 7 4 0 -1 0/);
  $mc->modal_map_reset;

  # or instead modal mapping by scale name (via Music::Scales)
  $mc->set_scale_intervals( 'input',  'minor'  );
  $mc->set_scale_intervals( 'output', 'dorian' );

And more!

=head1 DESCRIPTION

Musical canons involve horizontal lines of music (often called voices)
that are combined with other canon or free counterpoint voices to
produce harmony. This module assists with the creation of new voices.
Whether or not the output is usable is left to the composer. Harmony can
be created by careful selection of the input material and the mapping
settings, or perhaps by adding a free counterpoint voice to support the
canon voices. Analyzing the results with L<Music::Tension> may help
search for suitable material.

The methods of this module suit crab canon, as those lines are
relatively easy to calculate. Other forms of canon would ideally require
a counterpoint module, which has not yet been written.

Knowledge of canon will doubtless help any user of this module; the
L</"SEE ALSO"> section lists resources for learning these.

=head1 METHODS

Methods may B<die> or B<croak> under various conditions. B<new> would be
a good one to start with, then one of the C<*_map> functions to
transform the list of pitches into new material.

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

=item B<get_modal_pitches>

Returns the current modal input and output layer starting pitches (these
will be undefined if unset).

=item B<get_retrograde>

Returns the current retrograde setting (boolean). Retrograde is a fancy
way to indicate that the output list be reversed.

=item B<get_scale_intervals> I<layer>

Returns the current scale intervals for the indicated I<layer> (C<input>
or C<output>), or throws an exception if these are unset. The intervals
are returned as a list of two array references, the first for the scale
ascending, the second for the scale descending.

Note that descending scale intervals are noted from the lowest note up,
not highest note down.

=item B<get_transpose>

Returns the current transpose setting (integer of semitones or lilypond
note name, depending). Lilypond note names are preserved until
necessary, as to transpose to a lilypond note name, one must have the
pitch being transposed from, so that the delta between those two
pitches can be derived. Otherwise, given an integer, the transpose is
by that amount.

=item B<modal_map> I<phrase>

Modal mapping of the pitches in I<phrase> from an arbitrary input mode
to an arbitrary output mode, as set by B<set_scale_intervals>. Returns a
list, or throws an exception if a pitch cannot be converted. I<phrase>
may be a list or an array reference, and may contain raw pitch numbers,
objects that support a B<pitch> method, or other data that will be
passed through unchanged.

The algorithm operates by converting the intervals between the notes
into a number of diatonic steps in the input mode (and chromatic
adjustment, if necessary), then replaying that many steps in the output
(and chromatic adjustment, if necessary) mode, using the starting
pitches of the input phrase (first note) and output phrase (first note
of input phrase as affected by the B<transpose> setting) as the linkage
between the two modes.

An example may help illustrate this function. By default, the Major
scale to the Major scale conversion is used, which, with other
defaults set by this module, uses something like the following chart
to convert notes:

  In  | C  | c# | D | d# | E | F | f# | G | g# | A | a# | B | C' |
  Out | C' | x  | B | a# | A | G | f# | F | x  | E | d# | D | C  |

Assuming an input phrase of C<C G c#>, the output phrase would be C<C'
F> and then an exception would be thrown, as there is no way to convert
C<c#> using this mapping and transposition. Other mappings and
transpositions will have between zero to several notes that cannot be
converted.

B<modal_map> is affected by various settings, notably B<set_contrary>,
B<set_retrograde>, B<set_scale_intervals>, and B<set_transpose>.

Be sure to call B<modal_map_reset> when done converting a phrase.

=item B<modal_map_reset>

Resets the state variables associated with B<modal_map>.

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<new>

Constructor. Accepts a number of options, the useful or safe of which
are listed here.

=over 4

=item *

I<contrary> - sets the B<contrary> option. On by default.

=item *

I<input> - scale or Forte Number or interval set for the B<modal_map>
input mode. Defaults to the Major scale if unset. See
B<set_scale_intervals> and B<modal_map> for details.

=item *

I<keep_state> - configures whether state is maintained through
different calls to the various C<*_map> methods. On by default, which
will require the use of the corresponding C<*_map_reset> methods when a
phrase is complete. There are two possible workflows; with state
enabled, multiple calls can be made to the mapping function, which suits
B<modal_map> and the need to handle individual exceptions should a pitch
produce an undefined conversion:

  my $mc_state = Music::Canon->new;
  for my $e (@input) {
    my $result;
    eval { $result = $mc_state->modal_map($e) };
    if ($@ and $@ =~ m/undefined chromatic conversion/) {
      $result = 'r';   # make it a lilypond rest
    }
    push @output, $result;
  }
  $mc_state->modal_map_reset;

The other workflow is to disable state, and pass entire phrases for
conversion in one go. This better suits B<exact_map>, which unlike the
modal transformation will not have pitches it cannot convert:

  my $mc_no_state = Music::Canon->new(keep_state => 0);
  my @output = $mc_no_state->exact_map(\@input);

=item *

I<non_octave_scales> - configures whether scales should be bounded at an
octave (12 semitones) or not. The default is to complete interval sets
that sum up to less than 12 to include an additional element such that
the sum of the intervals is 12. Interval sets greater than 12 will cause
an exception to be thrown.

Enable this option only if dealing with a maqam or similar scale that is
not bounded by the Western notion of octave.

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

=item B<set_contrary> I<boolean>

Sets the contrary boolean (on by default). With this set, phrases
from the C<*_map> routines will be set in contrary motion to the
input phrase.

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_modal_pitches> I<input_start_pitch>, I<output_start_pitch>

Sets the starting pitches used for the B<modal_map> conversion. These by
default are derived from the first pitch passed to B<modal_map> and the
B<transpose> value; this method allows these pitches to be customized to
some other value.

  $mc->set_modal_pitches(60, 62);
  $mc->set_modal_pitches(undef, 64);  # just output start pitch
  $mc->set_modal_pitches(q{c'});      # by lilypond note

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_retrograde> I<boolean>

Sets the retrograde boolean (on by default). If set, phrases from the
C<*_map> routines will be reversed.

Returns the L<Music::Canon> object, so can be chained with other
method calls.

=item B<set_scale_intervals> I<layer>, I<asc>, [I<dsc>]

Sets the scale intervals for the indicated I<layer> (C<input> or
C<output>). The I<asc> (and optional I<dsc>) can be a number of
different things:

  $mc->set_scale_intervals('input', 'minor');  # Music::Scales
  $mc->set_scale_intervals('input', '7-23');   # Forte Number
  # arbitrary interval sequence
  $mc->set_scale_intervals('input', [qw/2 1 3 2 1 3 1/]);

If the I<dsc> is undefined, the corresponding I<asc> intervals will be
used, except for L<Music::Scales>, for which the descending intervals
associated with the ascending scale will be used.

NOTE that the descending intervals must be ordered from the lowest pitch
up. That is, melodic minor can be stated manually via:

  $mc->set_scale_intervals( 'output',
    [2,1,2,2,2,2],  # asc - c d ees f g a   b
    [2,1,2,2,1,2]   # dsc - c d ees f g aes bes
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

"Counterpointer" by Ars Nova (training software).

http://en.wikipedia.org/wiki/Forte_number

L<Music::AtonalUtil>, L<Music::LilyPondUtil>, L<Music::Scales>,
L<Music::Tension>

The C<scalemogrifier> utility of L<App::MusicTools> may also be
of interest.

=head1 AUTHOR

Jeremy Mates, E<lt>jmates@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Jeremy Mates

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself, either Perl version 5.16 or, at
your option, any later version of Perl 5 you may have available.

=cut