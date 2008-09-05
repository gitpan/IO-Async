#!/usr/bin/perl -w

use strict;

use IO::Async::Test;

use Test::More tests => 24;
use Test::Exception;
use Test::Refcount;

use IO::Async::ChildManager;

use POSIX qw( SIGTERM WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG );

use IO::Async::Loop::IO_Poll;

my $loop = IO::Async::Loop::IO_Poll->new();
is_oneref( $loop, '$loop has refcount 1' );

testing_loop( $loop );
is_refcount( $loop, 2, '$loop has refcount 2 after adding to IO::Async::Test' );

my $manager = IO::Async::ChildManager->new( loop => $loop );

ok( defined $manager, '$manager defined' );
isa_ok( $manager, "IO::Async::ChildManager", '$manager isa IO::Async::ChildManager' );

is_refcount( $loop, 2, '$loop has refcount 2 after constructing ChildManager' );

is_deeply( [ $manager->list_watching ], [], 'list_watching while idle' );

my $kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 3 );
}

my $exitcode;

$manager->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

ok( $manager->is_watching( $kid ), 'is_watching after adding $kid' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after adding $kid' );

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit' );
is( WEXITSTATUS($exitcode), 3, 'WEXITSTATUS($exitcode) after child exit' );

ok( !$manager->is_watching( $kid ), 'is_watching after child exit' );
is_deeply( [ $manager->list_watching ], [], 'list_watching after child exit' );

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   sleep( 10 );
   # Just in case the parent died already and didn't kill us
   exit( 0 );
}

$manager->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

ok( $manager->is_watching( $kid ), 'is_watching after adding $kid' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after adding $kid' );

$loop->loop_once( 0.1 );

ok( $manager->is_watching( $kid ), 'is_watching after loop' );
is_deeply( [ $manager->list_watching ], [ $kid ], 'list_watching after loop' );

kill SIGTERM, $kid;

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFSIGNALED($exitcode),          'WIFSIGNALED($exitcode) after SIGTERM' );
is( WTERMSIG($exitcode),    SIGTERM, 'WTERMSIG($exitcode) after SIGTERM' );

ok( !$manager->is_watching( $kid ), 'is_watching after child SIGTERM' );
is_deeply( [ $manager->list_watching ], [], 'list_watching after child SIGTERM' );

# Now lets test the integration with a ::Loop

$loop->detach_signal( 'CHLD' );
undef $manager;

$loop->enable_childmanager;

$kid = fork();
defined $kid or die "Cannot fork() - $!";

if( $kid == 0 ) {
   exit( 5 );
}

$loop->watch_child( $kid => sub { ( undef, $exitcode ) = @_; } );

undef $exitcode;
wait_for { defined $exitcode };

ok( WIFEXITED($exitcode),      'WIFEXITED($exitcode) after child exit for loop' );
is( WEXITSTATUS($exitcode), 5, 'WEXITSTATUS($exitcode) after child exit for loop' );

lives_ok( sub { $loop->disable_childmanager },
          'child manager can be disabled' );

is_refcount( $loop, 2, '$loop has refcount 2 at EOF' );