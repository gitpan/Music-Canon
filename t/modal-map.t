#!perl
#
# modal_map proved tricky enough to need an isolated test file

use strict;
use warnings;

use Test::More;    # plan is down at bottom
use Test::Exception;

eval 'use Test::Differences';    # display convenience
my $deeply = $@ ? \&is_deeply : \&eq_or_diff;

# for modal_map tests, see perldocs for chart showing where these occur
my @major_to_major_undefined = qw/-11 -4 1 8 13 20/;
my @mm_to_mm_undefined       = qw/-15 -11 -3 4 10 16/;

BEGIN { use_ok('Music::Canon') }
my $mc = Music::Canon->new;

########################################################################
#
# Modal Mappings, Major to Major
#
# These numbers worked out via a chart computed manually from -15 to 20.
# (the page width of my notebook)

# these all start on 0 and do not change the transpose so do not need to
# call reset_modal_pitches
$deeply->(
  [ $mc->modal_map(qw/0 0 2 2 4 5 7 9 11 12 14 16 17 19/) ],
  [qw/-19 -17 -15 -13 -12 -10 -8 -7 -5 -3 -1 -1 0 0/],
  'modal map diatonics up'
);
isa_ok( $mc->modal_map_reset, 'Music::Canon' );

$deeply->(
  [ $mc->modal_map(qw/0 -1 -3 -5 -7 -8 -10 -12 -13 -15/) ],
  [qw/16 14 12 11 9 7 5 4 2 0/],
  'modal map diatonics down'
);
$mc->modal_map_reset;

$deeply->(
  [ $mc->modal_map(qw/0 3 6 10 15 18/) ],
  [qw/-18 -14 -9 -6 -2 0/], 'modal map chromatics up'
);
$mc->modal_map_reset;

$deeply->(
  [ $mc->modal_map(qw/0 -2 -6 -9 -14/) ],
  [qw/15 10 6 3 0/], 'modal map chromatics down'
);
$mc->modal_map_reset;

for my $i (@major_to_major_undefined) {
  dies_ok(
    sub {
      my @surprise = $mc->modal_map( 0, $i );
      diag "error: instead of an exception got: @surprise for (0,$i)\n";
    },
    'undefined chromatic conversion'
  );
  # no per-loop-item reset as all start with 0 and then something that
  # should cause an exception
}

# Real Music(TM) test - yankee doodle fragment that goes above and below
# the link on the tonic (69 or a'). Need resets as switching to A-major
# to A-major conversions.
$mc->modal_map_reset;
isa_ok( $mc->set_modal_pitches( 69, 69 + 12 ), 'Music::Canon' );
$deeply->( [ $mc->get_modal_pitches ], [ 69, 69 + 12 ], 'get_modal_pitches' );

#$mc->set_transpose(12);

# so, modal pitches equal and transpose zero then start pitch same, unless
# the scales are radically different? also transpose before or after or maybe
# apply the steps? or maybe choice of how first pitch done? Hmm, or always
# applly the steps? If things the same, then Eb will step up to a Eb otherwise
# something else...
#
# Hmm, could do either $pitch + $transpose method directly (and from that start
# note then line things up to the output modal pitch) or always go through the
# modal pitches, with transpose thrown in as necessary. Optimization: input
# modal pitch should link to output modal pitch (unless tranpose).
#
# transpose bias would do a transpose, then figure out where subsequent pitches
# map to via the output mode, linking pitch. This may produce different results
# for the first and then subsequent pitches (like the floating V note and then
# I phrase in a fugue except here probably different)
#
# modal bias would do as much as possible via the modal pitches and steps from
# them, though with transpose in there somewhere if set. Given name of routine,
# this method favored. Soooo start pitch needs to roll through the steps thing.
# Plus transpose somehow.
$deeply->(
  [ $mc->modal_map(qw/64 69 69 71 73 74 73 71 69 68 64 66 68 69 69/) ],
  [qw/81 81 83 85 86 83 81 80 78 76 78 80 81 81 86/],
  'yankee doodle'
);

$mc->set_modal_pitches( 81, 69 );
$deeply->( [ $mc->get_modal_pitches ], [ 81, 69 ], 'get_modal_pitches' );

isa_ok( $mc->reset_modal_pitches, 'Music::Canon' );
$deeply->( [ $mc->get_modal_pitches ], [ undef, undef ], 'get_modal_pitches' );

########################################################################
#
# Modal Mappings, Melodic Minor
#
# These numbers also worked out via a chart computed manually from -15
# to 20 in notebook.

$mc = Music::Canon->new;

# melodic minor from Music::Scales and then manually
$mc->set_scale_intervals( 'input', 'mm' );
my @mm_via_scales = $mc->get_scale_intervals('input');

$mc->set_scale_intervals( 'output', [ 2, 1, 2, 2, 2, 2 ],
  [ 2, 1, 2, 2, 1, 2 ] );
my @mm_via_intervals = $mc->get_scale_intervals('output');
$deeply->(
  \@mm_via_intervals, \@mm_via_scales, 'Music::Scales vs. raw intervals'
);

$deeply->(
  [ $mc->get_scale_intervals('input') ],
  [ [qw/2 1 2 2 2 2 1/], [qw/2 2 1 2 2 1 2/] ],
  'melodic minor scale intervals'
);

$deeply->(
  [ $mc->modal_map(qw/0 1 2 3 5 6 7 8 9 11 12 13 14 15 17 18 19 20/) ],
  [qw/-20 -19 -18 -17 -16 -14 -13 -12 -10 -9 -8 -7 -6 -5 -4 -2 -1 0/],
  'modal map mm up'
);
$mc->modal_map_reset;

$deeply->(
  [ $mc->modal_map(qw/0 -1 -2 -4 -5 -6 -7 -8 -9 -10 -12 -13 -14/) ],
  [qw/14 13 12 11 9 8 7 6 5 3 2 1 0/],
  'modal map mm down'
);
$mc->modal_map_reset;

# From noodling about on keyboard in c-minor-ish, though starting on the
# third scale degree, which for c-minor that the linking pitches be set
# in advance, so that the mapping is based on C-to-?, not Eflat-to-? as
# would automatically happen without. Good news is that this noodling
# tripped over all sorts of bugs.
isa_ok( $mc->set_modal_pitches( 72, 72 ), 'Music::Canon' );
$deeply->( [ $mc->get_modal_pitches ], [ 72, 72 ], 'lookup modal pitches' );

$deeply->( [ $mc->modal_map(qw/75 74/) ], [qw/71 68/], 'yay bugs for 75 74' );
$mc->modal_map_reset;

$deeply->( [ $mc->modal_map(qw/80 79/) ], [qw/65 64/], 'yay bugs' );
$mc->modal_map_reset;

# these should not change after the various calls above...
$deeply->( [ $mc->get_modal_pitches ], [ 72, 72 ], 'lookup modal pitches' );
$deeply->(
  [ $mc->get_scale_intervals('input') ],
  [ [qw/2 1 2 2 2 2 1/], [qw/2 2 1 2 2 1 2/] ],
  'melodic minor scale intervals'
);

# Comparison with numbers worked out by hand in notebook using ASC to
# DSC and DSC to ASC as appropriate for the local motion under contrary
# output motion.
warn "ooh la la\n";
$mc->set_retrograde(0);
$deeply->(
  [ $mc->modal_map(
      qw/75 71 72 74 75 74 75 77 79 80
        79 84 83 84 80 79 77 80 79 77
        75 74 75 77 79 77 79 80 77 79
        77 75 74 75 74 72 71 72 74 75
        74 75 77 79 77 79 80 77 84 82
        80 79 80 79 77 75 77 75 74 72
        74 75 71 72/
    )
  ],
  [ qw/68 73 72 70 68 71 68 67 65 64 65 60 61 60 63 65 67 64 65 67 69 71 68 67 65 67 65 64 67 65 67 69 71 68 71 72 73 72 70 68 71 68 67 65 67 65 64 67 60 62 63 65 64 65 67 69 67 69 71 72 70 68 73 72/
  ],
  'modal map mm mixed directions'
);
$mc->modal_map_reset;
$mc->set_retrograde(1);

for my $i (@mm_to_mm_undefined) {
  dies_ok(
    sub {
      my @surprise = grep defined, $mc->modal_map( 0, $i );
      diag "error: instead of an exception got: '@surprise' for (0,$i)\n";
    },
    'undefined chromatic conversion'
  );
}

$mc = Music::Canon->new( non_octave_scales => 1 );
my @run_up   = 59 .. 86;
my @run_down = 32 .. 59;

# non_octave_scales tests - whole tone non-octave bounded modal_map is
# identical to exact_map (only more expensive to compute), due to the
# even interval spacing. However, it did uncover an edge case at the
# interval sum boundary of modal mapping, among other bugs.
$mc->set_scale_intervals( 'input',  '6-35' );
$mc->set_scale_intervals( 'output', '6-35' );
$deeply->( [ $mc->modal_map(@run_up) ], \@run_down, 'whole tone modal run up' );
$mc->modal_map_reset;
$deeply->(
  [ $mc->modal_map( reverse @run_down ) ],
  [ reverse @run_up ],
  'whole tone modal run down'
);

# TODO next would be 5-25, which should *not* line up on the 12-pitch
# octave with non-octave bounding (not that that octave has much to do
# with the algo, perhaps mostly to see what results are produced)

# TODO non-contrary motion tests (don't expect any problems but still)

# TODO non-zero starting pitch? (also with transpose?)

# TODO remote keys that have no overlaps, like say C Major to Db Major?

########################################################################
#
# chrome handling, also tricky, but only if the magnitude of an interval
# is greater than two (hungarian minor or for six-or-fewer note scales).

# C cis D -> Bes x B as there's no space between output pitch numbers 10
# and 11, regardless of how the chromes are handled.
sub impossible {
  $mc->set_modal_pitches( 0, 10 );
  $mc->set_scale_intervals( 'output', [ 1, 4, 1, 4 ] );
  dies_ok(
    sub {
      my $surprise = $mc->modal_map(1);
      diag "error: instead of an exception got: $surprise for 1\n";
    },
    'undefined chromatic conversion'
  );
}

# interval of 2 and chrome of 1 means there is only one option for the chrome
sub always_one {
  $mc->set_modal_pitches( 0, 8 );
  $mc->set_scale_intervals( 'output', [ 2, 1, 4, 1 ] );
  $deeply->( [ $mc->modal_map(1) ], [9], 'chrome +1' );
  $mc->modal_map_reset;
}

sub middle {
  $mc->set_modal_pitches( 48, 59 );
  $mc->set_scale_intervals( 'output', [ 4, 1, 4, 2 ] );
  $deeply->( [ $mc->modal_map(49) ], [61], 'somewhere in middle' );
  $mc->modal_map_reset;
}

$mc = Music::Canon->new( contrary => 0, retrograde => 0 );
impossible();
always_one();
middle();

$mc = Music::Canon->new( chrome_weight => 0, contrary => 0, retrograde => 0 );
impossible();
always_one();
middle();

$mc = Music::Canon->new( chrome_weight => -1, contrary => 0, retrograde => 0 );
impossible();
always_one();
$mc->set_modal_pitches( 48, 59 );
$mc->set_scale_intervals( 'output', [ 4, 1, 4, 2 ] );
$deeply->( [ $mc->modal_map(49) ], [60], 'negative literal' );
$mc->modal_map_reset;

$mc = Music::Canon->new( chrome_weight => 1, contrary => 0, retrograde => 0 );
impossible();
always_one();
$mc->set_modal_pitches( 48, 59 );
$mc->set_scale_intervals( 'output', [ 4, 1, 4, 2 ] );
$deeply->( [ $mc->modal_map(49) ], [62], 'positive literal' );
$mc->modal_map_reset;

# and back to the default
isa_ok( $mc->set_modal_chrome(0), 'Music::Canon' );
is( $mc->get_modal_chrome, 0, 'check chrome weighting' );
middle();

# TODO test and document negative interval steps (for exotic "scales"
# comprised of for example the intervals [-5,7]).

########################################################################

plan tests => 40 + @major_to_major_undefined + @mm_to_mm_undefined;
