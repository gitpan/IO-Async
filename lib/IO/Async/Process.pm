#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2011 -- leonerd@leonerd.org.uk

package IO::Async::Process;

use strict;
use warnings;
use base qw( IO::Async::Notifier );

our $VERSION = '0.39';

use Carp;

use POSIX qw(
   WIFEXITED WEXITSTATUS
);

use IO::Async::MergePoint;

=head1 NAME

C<IO::Async::Process> - start and manage a child process

=head1 SYNOPSIS

 use IO::Async::Process;

 use IO::Async::Loop;
 my $loop = IO::Async::Loop->new();

 my $process = IO::Async::Process->new(
    command => [ "tr", "a-z", "n-za-m" ],
    stdin => {
       from => "hello world\n",
    },
    stdout => {
       on_read => sub {
          my ( $stream, $buffref ) = @_;
          $$buffref =~ s/^(.*)\n// or return 0;

          print "Rot13 of 'hello world' is '$1'\n";
       },
    },
    
    on_finish => sub {
       $loop->loop_stop;
    },
 );

 $loop->add( $process );

 $loop->loop_forever;

=head1 DESCRIPTION

This subclass of L<IO::Async::Notifier> starts a child process, and invokes a
callback when it exits. The child process can either execute a given block of
code (via C<fork()>), or a command.

=cut

=head1 EVENTS

The following events are invoked, either using subclass methods or CODE
references in parameters:

=head2 on_finish $exitcode

Invoked after the process has exited by normal means (i.e. an C<exit(2)>
syscall from a process, or C<return>ing from the code block), and has closed
all its file descriptors.

=head2 on_exception $exception, $errno, $exitcode

Invoked when the process exits by an exception from C<code>, or by failing to
C<exec()> the given command. C<$errno> will be a dualvar, containing both
number and string values.

Note that this has a different name and a different argument order from
C<< Loop->open_child >>'s C<on_error>.

If this is not provided and the process exits with an exception, then
C<on_finish> is invoked instead, being passed just the exit code.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $process = IO::Async::Process->new( %args )

Constructs a new C<IO::Async::Process> object and returns it.

Once constructed, the C<Process> will need to be added to the C<Loop> before
the child process is started.

=cut

sub _init
{
   my $self = shift;
   $self->SUPER::_init( @_ );

   $self->{to_close}   = {};
   $self->{mergepoint} = IO::Async::MergePoint->new;
}

=head1 PARAMETERS

The following named parameters may be passed to C<new> or C<configure>:

=over 8

=item on_finish => CODE

=item on_exception => CODE

CODE reference for the event handlers.

=back

Once the C<on_finish> continuation has been invoked, the C<IO::Async::Process>
object is removed from the containing C<IO::Async::Loop> object.

The following parameters may be passed to C<new>, or to C<configure> before
the process has been started (i.e. before it has been added to the C<Loop>).
Once the process is running these cannot be changed.

=over 8

=item command => ARRAY or STRING

Either a reference to an array containing the command and its arguments, or a
plain string containing the command. This value is passed into perl's
C<exec()> function.

=item code => CODE

A block of code to execute in the child process. It will be called in scalar
context inside an C<eval> block.

=item setup => ARRAY

Optional reference to an array to pass to the underlying C<Loop>
C<spawn_child> method.

=item fdI<n> => HASH

A hash describing how to set up file descriptor I<n>. The hash may contain the
following keys:

=over 4

=item via => STRING

Configures how this file descriptor will be configured for the child process.
Must be given one of the following mode names:

=over 4

=item pipe_read

The child will be given the writing end of a C<pipe(2)>; the parent may read
from the other.

=item pipe_write

The child will be given the reading end of a C<pipe(2)>; the parent may write
to the other.

=item pipe_rdwr

Only valid on the C<stdio> filehandle. The child will be given the reading end
of one C<pipe(2)> on STDIN and the writing end of another on STDOUT. A single
Stream object will be created in the parent configured for both filehandles.

=back

Once the filehandle is set up, the C<fd> method (or its shortcuts of C<stdin>,
C<stdout> or C<stderr>) may be used to access the C<IO::Async::Stream> object
wrapped around it.

The value of this argument is implied by any of the following alternatives.

=item on_read => CODE

The child will be given the writing end of a pipe. The reading end will be
wrapped by an C<IO::Async::Stream> using this C<on_read> callback function.

=item into => SCALAR

The child will be given the reading end of a pipe. The referenced scalar will
be filled by data read from the child process. This data may not be available
until the pipe has been closed by the child.

=item from => STRING

The child will be given the reading end of a pipe. The string given by the
C<from> parameter will be written to the child. When all of the data has been
written the pipe will be closed.

=back

=item stdin => ...

=item stdout => ...

=item stderr => ...

Shortcuts for C<fd0>, C<fd1> and C<fd2> respectively.

=item stdio => ...

Special filehandle to affect STDIN and STDOUT at the same time. This
filehandle supports being configured for both reading and writing at the same
time.

=back

=cut

sub configure
{
   my $self = shift;
   my %params = @_;

   foreach (qw( on_finish on_exception )) {
      $self->{$_} = delete $params{$_} if exists $params{$_};
   }

   # All these parameters can only be configured while the process isn't
   # running
   my %setup_params;
   foreach (qw( code command setup stdin stdout stderr stdio ), grep { m/^fd\d+$/ } keys %params ) {
      $setup_params{$_} = delete $params{$_} if exists $params{$_};
   }

   if( $self->is_running ) {
      keys %setup_params and croak "Cannot configure a running Process with " . join ", ", keys %setup_params;
   }

   defined( exists $setup_params{code} ? $setup_params{code} : $self->{code} ) +
      defined( exists $setup_params{command} ? $setup_params{command} : $self->{command} ) <= 1 or
      croak "Cannot have both 'code' and 'command'";

   foreach (qw( code command setup )) {
      $self->{$_} = delete $setup_params{$_} if exists $setup_params{$_};
   }

   $self->configure_fd( 0, %{ delete $setup_params{stdin}  } ) if $setup_params{stdin};
   $self->configure_fd( 1, %{ delete $setup_params{stdout} } ) if $setup_params{stdout};
   $self->configure_fd( 2, %{ delete $setup_params{stderr} } ) if $setup_params{stderr};

   $self->configure_fd( 'io', %{ delete $setup_params{stdio} } ) if $setup_params{stdio};

   # All the rest are fd\d+
   foreach ( keys %setup_params ) {
      my ( $fd ) = m/^fd(\d+)$/ or croak "Expected 'fd\\d+'";
      $self->configure_fd( $fd, %{ $setup_params{$_} } );
   }

   $self->SUPER::configure( %params );
}

# These are from the perspective of the parent
use constant FD_VIA_PIPEREAD  => 1;
use constant FD_VIA_PIPEWRITE => 2;
use constant FD_VIA_PIPERDWR  => 3; # Only valid for stdio pseudo-fd

my %via_names = (
   pipe_read  => FD_VIA_PIPEREAD,
   pipe_write => FD_VIA_PIPEWRITE,
   pipe_rdwr  => FD_VIA_PIPERDWR,
);

sub configure_fd
{
   my $self = shift;
   my ( $fd, %args ) = @_;

   $self->is_running and croak "Cannot configure fd $fd in a running Process";

   if( $fd eq "io" ) {
      exists $self->{fd_handle}{$_} and croak "Cannot configure stdio since fd$_ is already defined" for 0 .. 1;
   }
   elsif( $fd == 0 or $fd == 1 ) {
      exists $self->{fd_handle}{io} and croak "Cannot configure fd$fd since stdio is already defined";
   }

   require IO::Async::Stream;

   my $handle = $self->{fd_handle}{$fd} ||= IO::Async::Stream->new(
      notifier_name => $fd eq "0"  ? "stdin" :
                       $fd eq "1"  ? "stdout" :
                       $fd eq "2"  ? "stderr" :
                       $fd eq "io" ? "stdio" : "fd$fd",
   );
   my $via = $self->{fd_via}{$fd};

   my ( $wants_read, $wants_write );

   if( my $via_name = delete $args{via} ) {
      defined $via and
         croak "Cannot change the 'via' mode of fd$fd now that it is already configured";

      $via = $via_names{$via_name} or
         croak "Unrecognised 'via' name of '$via_name'";
   }

   if( my $on_read = delete $args{on_read} ) {
      $handle->configure( on_read => $on_read );

      $wants_read++;
   }
   elsif( my $into = delete $args{into} ) {
      $handle->configure(
         on_read => sub {
            my ( undef, $buffref, $eof ) = @_;
            $$into .= $$buffref if $eof;
            return 0;
         },
      );

      $wants_read++;
   }

   if( my $from = delete $args{from} ) {
      $handle->write( $from,
         on_flush => sub {
            my ( $handle ) = @_;
            $handle->close_write;
         },
      );

      $wants_write++;
   }

   keys %args and croak "Unexpected extra keys for fd $fd - " . join ", ", keys %args;

   if( !defined $via ) {
      $via = FD_VIA_PIPEREAD  if  $wants_read and !$wants_write;
      $via = FD_VIA_PIPEWRITE if !$wants_read and  $wants_write;
      $via = FD_VIA_PIPERDWR  if  $wants_read and  $wants_write;
   }
   elsif( $via == FD_VIA_PIPEREAD ) {
      $wants_write and $via = FD_VIA_PIPERDWR;
   }
   elsif( $via == FD_VIA_PIPEWRITE ) {
      $wants_read and $via = FD_VIA_PIPERDWR;
   }
   elsif( $via == FD_VIA_PIPERDWR ) {
      # Fine
   }
   else {
      die "Need to check fd_via{$fd}\n";
   }

   $via == FD_VIA_PIPERDWR and $fd ne "io" and
      croak "Cannot both read and write simultaneously on fd$fd";

   defined $via and $self->{fd_via}{$fd} = $via;
}

sub _prepare_fds
{
   my $self = shift;
   my ( $loop ) = @_;

   my $fd_handle = $self->{fd_handle};
   my $fd_via    = $self->{fd_via};

   my $mergepoint = $self->{mergepoint};

   my @setup;

   foreach my $fd ( keys %$fd_via ) {
      my $handle = $fd_handle->{$fd};
      my $via    = $fd_via->{$fd};

      my $key = $fd eq "io" ? "stdio" : "fd$fd";

      if( $via == FD_VIA_PIPEREAD ) {
         my ( $myfd, $childfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";

         $handle->configure( read_handle => $myfd );

         push @setup, $key => [ dup => $childfd ];
         $self->{to_close}{$childfd->fileno} = $childfd;
      }
      elsif( $via == FD_VIA_PIPEWRITE ) {
         my ( $childfd, $myfd ) = $loop->pipepair() or croak "Unable to pipe() - $!";

         $handle->configure( write_handle => $myfd );

         push @setup, $key => [ dup => $childfd ];
         $self->{to_close}{$childfd->fileno} = $childfd;
      }
      elsif( $via == FD_VIA_PIPERDWR ) {
         $key eq "stdio" or croak "Oops - should only be FD_VIA_PIPERDWR on stdio";
         # Can't use pipequad here for now because we need separate FDs so we
         # can ->close them properly
         my ( $myread, $childwrite ) = $loop->pipepair() or croak "Unable to pipe() - $!";
         my ( $childread, $mywrite ) = $loop->pipepair() or croak "Unable to pipe() - $!";

         $handle->configure( read_handle => $myread, write_handle => $mywrite );

         push @setup, stdin => [ dup => $childread ], stdout => [ dup => $childwrite ];
         $self->{to_close}{$childread->fileno}  = $childread;
         $self->{to_close}{$childwrite->fileno} = $childwrite;
      }
      else {
         croak "Unsure what to do with fd_via==$via";
      }

      $mergepoint->needs( $key );
      $handle->configure(
         on_closed => sub {
            $mergepoint->done( $key );
         },
      );

      $self->add_child( $handle );
   }

   return @setup;
}

sub _add_to_loop
{
   my $self = shift;
   my ( $loop ) = @_;

   $self->{code} or $self->{command} or
      croak "Require either 'code' or 'command' in $self";

   my @setup;
   push @setup, @{ $self->{setup} } if $self->{setup};

   push @setup, $self->_prepare_fds( $loop );

   # Once we start the Process we'll close the MergePoint. Its on_finished
   # coderef will strongly reference $self. So we need to break this cycle.
   my $mergepoint = delete $self->{mergepoint};
   
   $mergepoint->needs( "exit" );

   my ( $exitcode, $dollarbang, $dollarat );

   $self->{pid} = $loop->spawn_child(
      code    => $self->{code},
      command => $self->{command},

      setup => \@setup,

      on_exit => sub {
         ( undef, $exitcode, $dollarbang, $dollarat ) = @_;
         $mergepoint->done( "exit" );
      },
   );
   $self->{running} = 1;

   $self->SUPER::_add_to_loop( @_ );

   $_->close for values %{ delete $self->{to_close} };

   my $is_code = defined $self->{code};

   $mergepoint->close(
      on_finished => sub {
         my %items = @_;

         $self->{exitcode} = $exitcode;
         $self->{dollarbang} = $dollarbang;
         $self->{dollarat}   = $dollarat;

         undef $self->{running};

         if( $is_code ? $dollarat eq "" : $dollarbang == 0 ) {
            $self->invoke_event( on_finish => $exitcode );
         }
         else {
            $self->maybe_invoke_event( on_exception => $dollarat, $dollarbang, $exitcode ) or
               # Don't have a way to report dollarbang/dollarat
               $self->invoke_event( on_finish => $exitcode );
         }

         $self->_remove_from_outer;
      },
   );
}

sub notifier_name
{
   my $self = shift;
   if( length( my $name = $self->SUPER::notifier_name ) ) {
      return $name;
   }

   return "nopid" unless my $pid = $self->pid;
   return "[$pid]" unless $self->is_running;
   return "$pid";
}

=head1 METHODS

=cut

=head2 $pid = $process->pid

Returns the process ID of the process, if it has been started, or C<undef> if
not. Its value is preserved after the process exits, so it may be inspected
during the C<on_finish> or C<on_exception> events.

=cut

sub pid
{
   my $self = shift;
   return $self->{pid};
}

=head2 $running = $process->is_running

Returns true if the Process has been started, and has not yet finished.

=cut

sub is_running
{
   my $self = shift;
   return $self->{running};
}

=head2 $exited = $process->is_exited

Returns true if the Process has finished running, and finished due to normal
C<exit()>.

=cut

sub is_exited
{
   my $self = shift;
   return defined $self->{exitcode} ? WIFEXITED( $self->{exitcode} ) : undef;
}

=head2 $status = $process->exitstatus

If the process exited due to normal C<exit()>, returns the value that was
passed to C<exit()>. Otherwise, returns C<undef>.

=cut

sub exitstatus
{
   my $self = shift;
   return defined $self->{exitcode} ? WEXITSTATUS( $self->{exitcode} ) : undef;
}

=head2 $exception = $process->exception

If the process exited due to an exception, returns the exception that was
thrown. Otherwise, returns C<undef>.

=cut

sub exception
{
   my $self = shift;
   return $self->{dollarat};
}

=head2 $errno = $process->errno

If the process exited due to an exception, returns the numerical value of
C<$!> at the time the exception was thrown. Otherwise, returns C<undef>.

=cut

sub errno
{
   my $self = shift;
   return $self->{dollarbang}+0;
}

=head2 $errstr = $process->errstr

If the process exited due to an exception, returns the string value of
C<$!> at the time the exception was thrown. Otherwise, returns C<undef>.

=cut

sub errstr
{
   my $self = shift;
   return $self->{dollarbang}."";
}

=head2 $stream = $process->fd( $fd )

Returns the L<IO::Async::Stream> associated with the given FD number. This
must have been set up by a C<configure> argument prior to adding the
C<Process> object to the C<Loop>.

The returned C<Stream> object have its read or write handle set to the other
end of a pipe connected to that FD number in the child process. Typically,
this will be used to call the C<write> method on, to write more data into the
child, or to set an C<on_read> handler to read data out of the child.

The C<on_closed> event for these streams must not be changed, or it will break
the close detection used by the C<Process> object and the C<on_finish> event
will not be invoked.

=cut

sub fd
{
   my $self = shift;
   my ( $fd ) = @_;

   return $self->{fd_handle}{$fd} or
      croak "$self does not have an fd Stream for $fd";
}

=head2 $stream = $process->stdin

=head2 $stream = $process->stdout

=head2 $stream = $process->stderr

=head2 $stream = $process->stdio

Shortcuts for calling C<fd> with 0, 1, 2 or C<io> respectively, to obtain the
L<IO::Async::Stream> representing the standard input, output, error, or
combined input/output streams of the child process.

=cut

sub stdin  { shift->fd( 0 ) }
sub stdout { shift->fd( 1 ) }
sub stderr { shift->fd( 2 ) }
sub stdio  { shift->fd( 'io' ) }

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>