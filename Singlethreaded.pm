package HTTP::Server::Singlethreaded;

use 5.006;
use strict;
use warnings;
use vars qw/

%Static 
%Function
%CgiBin
%Path


$DefaultMimeType
%MimeType

@Port
$Timeout
$MaxClients
$ServerType
$VERSION
$RequestTally
$uid $gid $forkwidth @kids
$WebEmail
/;


$RequestTally = 0;

# file number of request
my $fn;
# arrays indexed by $fn
my @Listeners;
my @Clients;
my @inbuf;
my @outbuf;
my @PortNo;

$VERSION = '0.01';

# default values:
$ServerType ||= __PACKAGE__." $VERSION (Perl $])";
@Port or @Port = (80,8000);
$Timeout ||= 5;
$MaxClients ||= 10;
$DefaultMimeType ||= 'text/plain';
keys(%MimeType ) or
  @MimeType{qw/txt htm html jpg gif png/} =
  qw{text/plain text/html text/html image/jpeg image/gif image/png};

sub Serve();
# use IO::Socket::INET;
use Socket  qw(:DEFAULT :crlf);
use Fcntl;
sub import(){

  print __PACKAGE__," import called\n";

  shift; # we don't need to know __PACKAGE__

  # DYNAMIC RECONFIGURATION SECTION
  my %args = @_;
  exists $args{port} and *Port = $args{port};
  exists $args{timeout} and *Timeout = $args{timeout};
  exists $args{maxclients} and *MaxClients = $args{maxclients};
  exists $args{static} and *Static = $args{static};
  exists $args{function} and *Function = $args{function};
  exists $args{cgibin} and *CgiBin = $args{cgibin};
  exists $args{servertype} and *ServerType = $args{servertype};
  exists $args{path} and *Path = $args{path};

  @Port or die __PACKAGE__." invoked with empty \@Port array";

  @Listeners = ();
  for (@Port) {
     my $l;
     socket($l, PF_INET, SOCK_STREAM,getprotobyname('tcp'))
        || die "socket: $!";
     fcntl($l, F_SETFL, O_NONBLOCK) 
        || die "can't set non blocking: $!";
     setsockopt($l, SOL_SOCKET,
                SO_REUSEADDR,
                pack("l", 1))
        || die "setsockopt: $!";
     bind($l, sockaddr_in($_, INADDR_ANY))
        || do {warn "bind: $!";next};
     listen($l,SOMAXCONN)
        || die "listen: $!";
     if (defined $l){
        print "bound listener to $_\n";
        $PortNo[fileno($l)] = $_;
        push @Listeners,$l;
     }else{
         print "Could not bind listener to $_\n";
     };
  } ;

  @Listeners or die __PACKAGE__." could not bind any listening sockets among @Port";

#   if($defined $uid){
#      $> = $< = $uid
#   };
# 
#   if($defined $gid){
#      $) = $( = $gid
#   };
# 
#   if($defined $forkwidth){
#      my $pid; my $i=0;
#      while (++$i < $forkwidth){
#         $pid = fork or last;
#         unshift @kids, $pid
#      };
#      unless($kids[0] ){
#        @kids=();
#      };
#      $forkwidth = "$i of $forkwidth";
#   };
#   END{ kill 'TERM', $_ for @kids };



   for (keys %Function){
      die "$Function{$_} is not a coderef"
        unless (ref $Function{$_} eq 'CODE');
      $Path{$_} = $Function{$_};
   }
   for (keys %Static){
      die "path $_ already defined" if exists $Path{$_};
      $Path{$_} = "STATIC $Static{$_}";
   }
   for (keys %CgiBin){
      die "path $_ already defined" if exists $Path{$_};
      $Path{$_} = "CGI $CgiBin{$_}";
   }

   {
      no strict;
      *{caller().'::Serve'} = \&Serve;
   }


};

my %RCtext =(
    100=> 'Continue',
    101=> 'Switching Protocols',
    200=> 'OK',
    201=> 'Created',
    202=> 'Accepted',
    203=> 'Non-Authoritative Information',
    204=> 'No Content',
    205=> 'Reset Content',
    206=> 'Partial Content',
    300=> 'Multiple Choices',
    301=> 'Moved Permanently',
    302=> 'Found',
    303=> 'See Other',
    304=> 'Not Modified',
    305=> 'Use Proxy',
    306=> '(Unused)',
    307=> 'Temporary Redirect',
    400=> 'Bad Request',
    401=> 'Unauthorized',
    402=> 'Payment Required',
    403=> 'Forbidden',
    404=> 'Not Found',
    405=> 'Method Not Allowed',
    406=> 'Not Acceptable',
    407=> 'Proxy Authentication Required',
    408=> 'Request Timeout',
    409=> 'Conflict',
    410=> 'Gone',
    411=> 'Length Required',
    412=> 'Precondition Failed',
    413=> 'Request Entity Too Large',
    414=> 'Request-URI Too Long',
    415=> 'Unsupported Media Type',
    416=> 'Requested Range Not Satisfiable',
    417=> 'Expectation Failed',
    500=> 'Internal Server Error',
    501=> 'Not Implemented',
    502=> 'Bad Gateway',
    503=> 'Service Unavailable',
    504=> 'Gateway Timeout',
    505=> 'HTTP Version Not Supported'
); 



sub dispatch(){
# based on the request, which is in $_,
# figure out what to do, and do it.
# return a numeric resultcode in $ResultCode
# and data in $Data

   # defaults:
   @_{qw/Data ResultCode/}=(undef,200);

   # rfc2616 section 5.1
   /^(\w+) (\S+) HTTP\/(\S+)\s*(.*)$CRLF$CRLF/s
      or do { $_{ResultCode} = 400;
              return <<EOF;
Content-type:text/plain

This server only accepts requests that
match the perl regex
/^(\\w+) (\\S+) HTTP\\/(\\S+)/

EOF
   };
   @_{qw/Method URI HTTPver RequestHeader/} = ($1,$2,$3,$4);

   @_{qw/URIpath QUERY_STRING/} = $_{URI}=~m#(/[^\?]*)\??(.*)#;
   $_{URIpath} =~ s/%(..)/chr hex $1/ge; # RFC2616 sec. 3.2
   my @URIpath = split '/',$_{URIpath}; 
   my @Castoffs;
   my $mypath;
   while (@URIpath){
      $mypath = join '/',@URIpath,'';
      print "considering $mypath\n";
      if (exists $Path{$mypath}){
         print "$mypath => $Path{$mypath}\n";
         $_{PATH_INFO} = join '/', @Castoffs;
         print "PATH_INFO is $_{PATH_INFO}\n";
         if (ref $Path{$mypath}){
            my $DynPage;
            eval {
               $DynPage = &{$Path{$mypath}};
            };
            $@ or return $DynPage;
            $_{ResultCode} = 500;
            return <<EOF;
Content-type:text/plain

Internal server error while processing routine
for $mypath:

$@
EOF
         };
         if ($Path{$mypath} =~/^STATIC (.+)/){
            my $filename = "$1/$_{PATH_INFO}";
            print "filename: $filename\n";
            $filename =~ s/\/\.\.\//\//g; # no ../../ attacks
            my ($ext) = $filename =~ /\.(\w+)$/;
            my $ContentType = $MimeType{$ext}||$DefaultMimeType;
            # unless (-f $filename and -r _ ){
            unless(open FILE, "<", $filename){
               $_{ResultCode} = 404;
               return <<EOF;
Content-type: text/plain

Could not open $filename for reading
$!

for $mypath: $Path{$mypath}

Request:

$_

EOF
            };
            # range will go here when supported
            sysread FILE, my $slurp, -s $filename;
            return "Content-type: $ContentType\n\n$slurp";

         };
         $_{ResultCode} = 404;
         return <<EOF;
Content-type:text/plain

This version of Singlethreaded does not understand
how to serve

$mypath

$Path{$mypath}

Responsible person: $WebEmail

We received this request:

$_

EOF
      };
      unshift @Castoffs, pop @URIpath;
   };


   $_{ResultCode} = 404;
   <<EOF;
Content-type:text/plain

$$ $RequestTally handling fileno $fn

apparently this Singlethreaded server does not
have a default handler installed at its 
virtual root.

Responsible person: $WebEmail

$_

EOF

};


sub HandleRequest(){
   $RequestTally++;
   print "Handling request $RequestTally on fn $fn\n";
   # print "Inbuf:\n$inbuf[$fn]\n";
   *_ = \delete $inbuf[$fn]; # tight, huh?
   
   my $dispatchretval = dispatch;
   $_{Data} ||= $dispatchretval;
   $outbuf[$fn]=<<EOF;  # change to .= if/when we support pipelining
HTTP/1.1 $_{ResultCode} $RCtext{$_{ResultCode}}
Server: $ServerType
$_{Data}
EOF

  # is this necessary?
  $outbuf[$fn] =~ s/$CR//g; 
  $outbuf[$fn] =~ s/$LF/$CRLF/g; 

};

my $client_tally = 0;
sub Serve(){
   print "L: (@Listeners) C: (@Clients)\n";
   my ($rin,$win,$ein,$rout,$wout,$eout);
   my $nfound;


   # poll for new connections?
   my $Accepting = ($client_tally < $MaxClients);
   $rin = $win = $ein = '';
   if($Accepting){
      for(@Listeners){
         $fn = fileno($_);
         vec($rin,$fn,1) = 1;
         vec($win,$fn,1) = 1;
         vec($ein,$fn,1) = 1;
      };
   };


   my @Outs;
   my @CompleteRequests;
   # list all clients in $ein and $rin
   # list connections with pending outbound data in $win;
   for(@Clients){
      $fn = fileno($_);
      vec($rin,$fn,1) = 1;
      vec($ein,$fn,1) = 1;
      if( length $outbuf[$fn]){
         vec($win,$fn,1) = 1;
         push @Outs, $_;
      }
   };

   # Select.
   $nfound = select($rout=$rin, $wout=$win, $eout=$ein, $Timeout);
   $nfound > 0 or return;
   # accept new connections
   if($Accepting){
      for(@Listeners){
         vec($rout,fileno($_),1) or next;
         # relies on listeners being nonblocking
         # thanks, thecap
         # (at http://www.perlmonks.org/index.pl?node_id=6535)
         while (accept(my $NewServer, $_)){
         # if (accept(my $NewServer, $_)){
            $fn =fileno($NewServer); 
            $inbuf[$fn] = $outbuf[$fn] = '';
            print "Accepted $NewServer (",
                  $fn,") ",
                  ++$client_tally,
                  "/$MaxClients on $_ ($fn) port $PortNo[fileno($_)]\n";
            push @Clients, $NewServer;
         }
      }
   } # if accepting connections

   # Send outbound data from outbufs 
   my $wlen;
   for(@Outs){
      $fn = fileno($_);
      vec($wout,$fn,1) or next;
      $wlen = syswrite $_, $outbuf[$fn], length($outbuf[$fn]);
      defined $wlen or print "Error on socket $_ ($fn): $!\n";
      substr $outbuf[$fn], 0, $wlen, '';
      # rewrite this when adding keepalive support
      length($outbuf[$fn]) or close $_;
   }

   # read incoming data to inbufs and list inbufs with complete requests
   # close bad connections
   for(@Clients){
      defined($fn = fileno($_)) or next;
      if(vec($rout,$fn,1)){

         my $char;
         sysread $_,$char,64000;
	 if(length $char){
		$inbuf[$fn] .= $char;
                # CompleteRequest
                substr($inbuf[$fn],-4,4) eq "\015\012\015\012"
                 and
                   push @CompleteRequests, $fn;
	 }else{
            print "Received empty packet on $_ ($fn)\n";
		 print "CLOSING fd $fn\n";
                 close $_ or print "error on close: $!\n";
                 $client_tally--;
                 print "down to $client_tally / $MaxClients\n";
	 };
      }
      if(vec($eout,$fn,1)){
         # close this one
         print "error on $_ ($fn)\n";
	 print "CLOSING fd $fn\n";
         close $_ or print "error on close: $!\n";
      };
   }

   # prune @Clients array

   @Clients = grep { defined fileno($_) } @Clients;
   $client_tally = @Clients;
   print "$client_tally / $MaxClients\n";

   # handle complete requests
   # (outbound data will get written next time)
   for $fn (@CompleteRequests){

      HandleRequest

   };



};




1;
__END__

=head1 NAME

HTTP::Server::Singlethreaded - a framework for standalone web applications

=head1 SYNOPSIS

  # configuration first:
  #
  BEGIN { # so the configuration happens before import() is called
  # static directories are mapped to file paths in %Static
  $HTTP::Server::Singlethreaded::Static{'/images/'} = '/var/www/images';
  $HTTP::Server::Singlethreaded::Static{'/'} = '/var/www/htdocs';
  #
  # configuration for serving static files (defaults are shown)
  $HTTP::Server::Singlethreaded::DefaultMimeType = 'text/plain';
  @HTTP::Server::Singlethreaded::MimeType{qw/txt htm html jpg gif png/} =
  qw{text/plain text/html text/html image/jpeg image/gif image/png};
  #
  # internal web services are declared in %Functions 
  $HTTP::Server::Singlethreaded::Function{'/AIS/'} = \&HandleAIS;
  #
  # external CGI-BIN directories are declared in %CgiBin
  # NOT IMPLEMENTED YET
  $HTTP::Server::Singlethreaded::CgiBin{'/cgi/'} = '/var/www/cgi-bin';
  #
  # @Port where we try to listen
  @HTTP::Server::Singlethreaded::Port = (80,8000);
  #
  # Timeout for the selecting 
  $HTTP::Server::Singlethreaded::Timeout = 5
  #
  # overload protection
  $HTTP::Server::Singlethreaded::MaxClients = 10
  #
  }; # end BEGIN
  # merge path config and open listening sockets
  use HTTP::Server::Singlethreaded;
  #
  # "top level select loop" is invoked explicitly
  for(;;){
    #
    # manage keepalives on database handles
    if ((time - $lasttime) > 40){
       ...
       $lasttime = time;
    };
    #
    # do pending IO, invoke functions, read statics
    # HTTP::Server::Singlethreaded::Serve()
    Serve(); # this gets exported
  }

=head1 DESCRIPTION

HTTP::Server::Singlethreaded is a framework for providing web applications without
using a web server (apache, boa, etc.) to handle HTTP.

=head1 CONFIGURATION

One of %Static, %Function, %CgiBin should contain a '/' key, this will
handle just the domain name, or a get request for /.

=head2 %Static

the %Static hash contains paths to directories where files can be found
for serving static files.

=head2 %Function
Paths to functions => functions to run.  Functions should take exactly one
argument, which will be the entire server request.

=head2 %CgiBin

CgiBin is a functional wrapper that forks and executes a named executable program,
after setting the common gateway interface environment variables and changing
directory to the listed directory. NOT IMPLEMENTED IN THIS VERSION

=head2 @Port

the C<@Port> array lists the ports the server tries to listen on.

=head2 name-based virtual hosts

not implemented yet; a few configuration interfaces are possible,
most likely a hash of host names that map to strings that will be
prepeneded to the key looked up in %Path.

=head2 $Timeout

the timeout for the select 

=head2 $MaxClients

if we have more active clients than this we won't accept more. Since
we're not respecting keepalive at this time, this number indicates
how long of a backlog singlethreaded will maintain at any moment.

=head2 $WebEmail

an e-mail address for whoever is responsible for this server,
for use in error messages.

=head2 $forkwidth

Set $forkwidth to a number greater than 1
to have singlethreaded fork after binding. If running on a
multiprocessor machine for instance, or if you want to verify
that the elevator algorithm works. After C<import()>, $forkwidth
is altered to indicate which process we are in, such as
"2 of 3". The original gets an array of the process IDs of all
the children in @kids, as well as a $forkwidth variable that
matches C</(\d+) of \1/>. Also, all children are sent a TERM
signal from the parent process's END block.  Uncomment the
relevant lines if you need this.

=head2 $uid and $gid

when starting as root in a *nix, specify these numerically. The
process credentials will be changed after the listening sockets
are bound.

=head1 Dynamic Reconfiguration

Dynamic reconfiguration is possible, either by directly altering
the configuration variables or by passing references to import().
If you can't see how to do this from looking at the source, an
attempted explanation here would probably just waste your time.

=head1 Action Selection Method

The request is split on slashes, then matched against the configuration
hashes until there is a match.  Longer matching pieces trump shorter ones.

Having the same path listed in more than one of %Static, %Functions, or %CgiBin is
an error and the server will not start in that case. 

=head1 Writing Functions For Use With HTTP::Server::Singlethreaded

This framework uses the C<%_> hash for passing data between elements
which are in different packages.

=head2 Data you get

=head3 the whole enchilada

The full RFC2616-sec5 HTTP Request is available for inspection in C<$_>.
Certain parts have been parsed out and are available in C<%_>. These
include

=head3 Method

Your function can access all the HTTP methods. You are not restricted
to GET or POST as with the CGI environment.

=head3 URI

Whatever the client asked for.

=head3 HTTPver

such as C<1.1>

=head3 QUERY_STRING, PATH_INFO

as in CGI

=head2 Data you give

The HandleRequest() function looks at two data only:

=head3 ResultCode

C<$_{ResultCode}> defaults to 200 on success and gets set to 500
when your function dies.  C<$@> will be included in the output.
Singlethreaded knows all the result code strings defined in RFC2616.

=head3 Data

Store your complete web page output into C<$_{Data}>, just as you
would write output starting with server headers when writing
a simple CGI program. Or leave $_{Data} alone and return a valid
page, beginning with headers.


=head1 AVOIDING DEADLOCKS

The server blocks while slurping files and executing functions, at this
version. So singlethreaded is not appropriate for serving large files.

=head1 What Singlethreaded is good for

Singlethreaded is designed to provide a web interface to a database,
leveraging a single persistent DBI handle into an unlimited number
of simultaneous HTTP requests.

=head1 HISTORY

=over 8

=item 0.01

August 18, 2004.  %CgiBin is not yet implemented.

=back

=head1 EXPORTS

C<Serve()> is exported.

=head1 AUTHOR

David Nicol E<lt>davidnico@cpan.orgE<gt> 

This module is released AL/GPL, the same terms as Perl.

=head1 References

Paul Tchistopolskii's public domain phttpd 

HTTP::Daemon

the University of Missouri - Kansas City Task Definition Interface

perlmonks

=cut
