#!/usr/bin/perl

use strict;
use warnings;

use IO::Async::Loop;
use IO::Async::Stream;

my $CRLF = "\x0d\x0a"; # because \r\n is not portable

my $HOST = shift @ARGV or die "Need HOST";
my $PORT = shift @ARGV or die "Need PORT";

my $loop = IO::Async::Loop->new;

my $socket;

$loop->connect(
   host     => $HOST,
   service  => $PORT,
   socktype => 'stream',

   on_connected => sub { $socket = shift },

   on_resolve_error => sub { die "Cannot resolve - $_[0]\n" },
   on_connect_error => sub { die "Cannot connect\n" },
);

$loop->loop_once until defined $socket;

# $socket is just an IO::Socket reference
my $peeraddr = $socket->peerhost . ":" . $socket->peerport;

print STDERR "Connected to $peeraddr\n";

# We need to create a cross-connected pair of Streams. Can't do that
# easily without a temporary variable
my ( $socketstream, $stdiostream );

my $quit_mergepoint = IO::Async::MergePoint->new(
   needs => [qw[ socket stdio ]],

   on_finished => sub { $loop->loop_stop },
);

$socketstream = IO::Async::Stream->new(
   handle => $socket,

   on_read => sub {
      my ( undef, $buffref, $closed ) = @_;

      if( $$buffref =~ s/^(.*)$CRLF// ) {
         $stdiostream->write( $1 . "\n" );
         return 1;
      }

      return 0;
   },

   on_closed => sub {
      print STDERR "Closed connection to $peeraddr\n";
      $quit_mergepoint->done( 'socket' );
      $stdiostream->close_when_empty;
   },
);
$loop->add( $socketstream );

$stdiostream = IO::Async::Stream->new(
   read_handle  => \*STDIN,
   write_handle => \*STDOUT,

   on_read => sub {
      my ( undef, $buffref, $closed ) = @_;

      if( $$buffref =~ s/^(.*)\n// ) {
         $socketstream->write( $1 . $CRLF );
         return 1;
      }

      return 0;
   },

   on_closed => sub {
      $quit_mergepoint->done( 'stdio' );
      $socketstream->close_when_empty;
   },
);
$loop->add( $stdiostream );

$loop->loop_forever;