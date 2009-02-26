#!/usr/bin/perl -w

use strict;

use Test::More tests => 4;
use Test::Exception;

use IO::Async::Loop;
use IO::Async::Stream;

my $loop = IO::Async::Loop->new();

my ( $S1, $S2 ) = $loop->socketpair() or die "Cannot create socket pair - $!";

# Need sockets in nonblocking mode
$S1->blocking( 0 );
$S2->blocking( 0 );

my $closed = 0;
my $loop_during_closed;

my $stream = IO::Async::Stream->new( handle => $S1,
   on_read   => sub { },
   on_closed => sub {
      my ( $self ) = @_;
      $closed = 1;
      $loop_during_closed = $self->get_loop;
   },
);

$stream->write( "hello" );

$loop->add( $stream );

is( $closed, 0, 'closed before close' );

$stream->close_when_empty;

is( $closed, 0, 'closed after close' );

$loop->loop_once( 1 ) or die "Nothing ready after 1 second";

is( $closed, 1, 'closed after wait' );
is( $loop_during_closed, $loop, 'loop during closed' );
