#!perl
#
# Weaving a safety net being a tedious and thankless task in the
# short term...

use strict;
use warnings;

use Test::More;    # plan is down at bottom

eval 'use Test::Differences';    # display convenience
my $deeply = $@ ? \&is_deeply : \&eq_or_diff;

########################################################################
#
# Defaults and Initial Mode Setup

BEGIN { use_ok('Music::Canon') }

my $mc = Music::Canon->new;
isa_ok( $mc, 'Music::Canon' );

# defaults
is( $mc->get_transpose,  0, 'default transpose' );
is( $mc->get_contrary,   1, 'default contrary' );
is( $mc->get_retrograde, 1, 'default retrograde' );

# major/major the default
$deeply->(
  [ $mc->get_scale_intervals('input') ],
  [ [qw(2 2 1 2 2 2 1)], [qw(1 2 2 2 1 2 2)] ],
  'major intervals check input'
);
$deeply->(
  [ $mc->get_scale_intervals('output') ],
  [ [qw(2 2 1 2 2 2 1)], [qw(1 2 2 2 1 2 2)] ],
  'major intervals check output'
);

# set intervals by scale name (via Music::Scales)
my $resp = $mc->set_scale_intervals( 'input', 'aeolian' );
isa_ok( $resp, 'Music::Canon' );

# or by interval (aeolian again)
$resp = $mc->set_scale_intervals( 'output', [qw/2 1 2 2 1 2 2/] );
isa_ok( $resp, 'Music::Canon' );

$deeply->(
  [ $mc->get_scale_intervals('input') ],
  [ [qw(2 1 2 2 1 2 2)], [qw(2 2 1 2 2 1 2)] ],
  'minor intervals check input'
);
$deeply->(
  [ $mc->get_scale_intervals('output') ],
  [ [qw(2 1 2 2 1 2 2)], [qw(2 2 1 2 2 1 2)] ],
  'minor intervals check output'
);

# and adjusting only dsc intervals
$mc->set_scale_intervals( 'output', undef, [qw/2 2 2 2 2 2/] );
$deeply->(
  [ $mc->get_scale_intervals('output') ],
  [ [qw(2 1 2 2 1 2 2)], [qw(2 2 2 2 2 2)] ],
  'custom dsc intervals check'
);

########################################################################
#
# Exact Mappings

$mc = Music::Canon->new;

$deeply->( [ $mc->exact_map(qw/0 1 2/) ], [qw/-2 -1 0/], 'exact map' );
isa_ok( $mc->exact_map_reset, 'Music::Canon' );

# vs. individual calls for each note
{
  my @input = qw/0 1 2/;
  my @output;
  for my $p (@input) {
    push @output, $mc->exact_map($p);
  }

  # Retrograde is meaningless if doing note-by-note calls, as there is
  # never anything that can be reversed...
  @output = reverse @output if $mc->get_retrograde;

  $deeply->( \@output, [qw/-2 -1 0/], 'exact map multiple calls' );
  $mc->exact_map_reset;
}

isa_ok( $mc->set_transpose(60), 'Music::Canon' );
$deeply->(
  [ $mc->exact_map(qw/2 9 5 2 1 2 4 5/) ],
  [qw/59 60 62 63 62 59 55 62/]
);

########################################################################
#
# getters/setters

$mc = Music::Canon->new;

isa_ok( $mc->set_contrary(0), 'Music::Canon' );
is( $mc->get_contrary, 0, 'set contrary false' );
$mc->set_contrary(1);
is( $mc->get_contrary, 1, 'set contrary true' );

isa_ok( $mc->set_retrograde(0), 'Music::Canon' );
is( $mc->get_retrograde, 0, 'set retrograde false' );
$mc->set_retrograde(1);
is( $mc->get_retrograde, 1, 'set retrograde true' );

# transpose to a note defers the conversion to a pitch until have the
# starting pitch of the input phrase so can convert from that pitch to
# the desired lilypond note
$mc->set_transpose(q{c'});
is( $mc->get_transpose, q{c'}, 'transpose to lilypond note' );

$mc = Music::Canon->new( keep_state => 0 );

# some value that is probably not set by default
my $rand_transpose = 200 + int rand 100;
$mc->set_transpose($rand_transpose);
is( $mc->get_transpose, $rand_transpose, 'get rand transpose' );

my @phrase = qw/0 1 2 1 0 -1 -2 -1 0/;
$mc->set_contrary(0);
$mc->set_retrograde(0);
$deeply->(
  [ $mc->exact_map( \@phrase ) ],
  [ map { $_ += $rand_transpose } @phrase ],
  'exact map via rand transpose'
);
# should not need due to keep_state => 0
#$mc->exact_map_reset;

$mc->set_transpose;
is( $mc->get_transpose, 0, 'reset transpose' );

# phrase that does not start on zero, as there shouldn't be anything
# special about what the starting pitch is.
@phrase = map { $_ += 10 + int rand 10 } @phrase;
$deeply->( [ $mc->exact_map( \@phrase ) ], \@phrase,
  'start on non-zero pitch' );

########################################################################
#
# Yet More Tests

$mc = Music::Canon->new;

# Forte Numbers!
$mc->set_scale_intervals( 'input', '5-35', '5-25' );
$deeply->(
  [ $mc->get_scale_intervals('input') ],
  [ [qw/2 2 3 2 3/], [qw/4 3 2 1 2/] ],
  'scale intervals by Forte'
);

$mc = Music::Canon->new( non_octave_scales => 1 );
my @run_up   = 59 .. 86;
my @run_down = 32 .. 59;
$deeply->( [ $mc->exact_map(@run_up) ], \@run_down, 'exact run up' );
$mc->exact_map_reset;
$deeply->(
  [ $mc->exact_map( reverse @run_down ) ],
  [ reverse @run_up ],
  'exact run down'
);

plan tests => 31;
