#!perl
#
# modal_map proved tricky enough to need a bad sequel (or was never really
# fully thought through wrt transpose).

use strict;
use warnings;

use Test::More;    # plan is down at bottom

eval 'use Test::Differences';    # display convenience
my $deeply = $@ ? \&is_deeply : \&eq_or_diff;

BEGIN { use_ok('Music::Canon') }
my $mc = Music::Canon->new;

# some more scale tests + transpose
$mc = Music::Canon->new( contrary => 0, retrograde => 0 );
$mc->set_transpose(4);
$deeply->(
  [ $mc->modal_map( 60, 59, 57, 55, 53, 52, 50, 48 ) ],
  [ 64, 62, 60, 59, 57, 55, 53, 52 ],
  'Major I->iii'
);

$mc = Music::Canon->new( contrary => 0, retrograde => 0 );
# Middle c (60) -> g (55) in g-minor, transpose from scale degree 1 (g)
# to 3 (bes)
# $mc->set_modal_pitches( 55, 58 );
$mc->set_scale_intervals( input  => 'aeolian' );
$mc->set_scale_intervals( output => 'aeolian' );
$mc->set_transpose('bes');
# 'got' pattern not possible using scale intervals? something cut?
$deeply->(
  [ $mc->modal_map( 55, 53, 51, 50, 48, 46, 45, 43 ) ],
  [ 58, 57, 55, 53, 51, 50, 48, 46 ],
  'minor i->III'
);

# TODO need to work out handling of transpose to chromatic or unpossible scale
# degrees.

plan tests => 3;
