#!perl
use 5.010000;
use strict;
use warnings FATAL => 'all';
use Test::More;

plan tests => 1;

BEGIN {
  use_ok('Music::Canon') || print "Bail out!\n";
}

diag("Testing Music::Canon $Music::Canon::VERSION, Perl $], $^X");
