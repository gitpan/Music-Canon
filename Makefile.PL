#!perl

use 5.010000;

use strict;
use warnings;
use ExtUtils::MakeMaker;

my %params = (
  NAME         => 'Music::Canon',
  ABSTRACT     => 'routines for musical canon construction',
  VERSION_FROM => 'lib/Music/Canon.pm',
  PREREQ_PM    => {
    Carp                  => 0,
    'List::Util'          => 0,
    'Music::AtonalUtil'   => 1.00,
    'Music::LilyPondUtil' => 0.43,
    'Music::Scales'       => 0.07,
    'Test::Exception'     => 0,
    'Test::More'          => 0,
    'Try::Tiny'           => 0,
  },
  ( $] >= 5.005
    ? ( AUTHOR => 'Jeremy Mates <jmates@cpan.org>' )
    : ()
  ),
);

if ( $ExtUtils::MakeMaker::VERSION =~ /^\d\.\d\d$/ and $ExtUtils::MakeMaker::VERSION > 6.30 ) {
  $params{LICENSE} = 'perl';
}

if ( $ExtUtils::MakeMaker::VERSION ge '6.46' ) {
  $params{META_MERGE} = {
    resources => {
      homepage   => 'http://github.com/thrig/Music-Canon',
      license    => 'http://dev.perl.org/licenses/',
      repository => 'http://github.com/thrig/Music-Canon',
    }
  };
}

if ( $ExtUtils::MakeMaker::VERSION ge '6.48' ) {
  $params{MIN_PERL_VERSION} = 5.010000;
}

WriteMakefile(%params);
