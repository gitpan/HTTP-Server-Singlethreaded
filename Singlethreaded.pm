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
$StaticBufferSize
/;

sub DEBUG() {0};

$RequestTally = 0;
$StaticBufferSize ||= 50000;

# file number of request
my $fn;
# arrays indexed by $fn
my @Listeners;    # handles to listening sockets
my @PortNo;       # listening port numbers indexed by $fn
my @PeerAddr;     # PEER_ADDR
my @Clients;      # handles to client sockets
my @inbuf;        # buffered information read from clients
my @outbuf;       # buffered information for writing to clients
my @LargeFile;    # handles to large files being read, indexed by
                  # $fn of the client they are being read for
my @continue;     # is there a continuation defined for this fn?
my @poll;         # do we know how to poll a continuation for readiness?
my @PostData;     # data for POST-style requests

#lists of file numbers
my @PollMe;       #continuation functions associated with empth output buffers

$VERSION = '0.05';

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
BEGIN{
	use Fcntl;
        # determine if O_NONBLOCK works
        # for use in fcntl($l, F_SETFL, O_NONBLOCK) 
        eval{
          # print "O_NONBLOCK is ",O_NONBLOCK,
          #      " and F_SETFL is ",F_SETFL,"\n";
          O_NONBLOCK; F_SETFL;
        };
        if ($@){
           # print "O_NONBLOCK is broken, but a workaround is in place.\n";
	   eval'sub BROKEN_NONBLOCKING(){1}';
        }else{
	   eval'sub BROKEN_NONBLOCKING(){0}';
        };
}

sub makeref($){
	ref($_[0]) ? $_[0] : \$_[0]
};

sub import(){

  print __PACKAGE__," import called\n";

  shift; # we don't need to know __PACKAGE__

  # DYNAMIC RECONFIGURATION SECTION
  my %args = @_;
  DEBUG and do{
	print "$_ is $args{$_}\n" foreach sort keys %args

  };
  exists $args{port} and *Port = $args{port};
  exists $args{timeout} and *Timeout = $args{timeout};
  exists $args{maxclients} and *MaxClients = $args{maxclients};
  exists $args{static} and *Static = $args{static};
  exists $args{function} and *Function = $args{function};
  exists $args{cgibin} and *CgiBin = $args{cgibin};
  exists $args{servertype} and *ServerType = $args{servertype};
  exists $args{webemail} and *WebEmail = makeref($args{webemail});
  exists $args{path} and *Path = $args{path};

  @Port or die __PACKAGE__." invoked with empty \@Port array";

  @Listeners = ();
  for (@Port) {
     my $l;
     socket($l, PF_INET, SOCK_STREAM,getprotobyname('tcp'))
        || die "socket: $!";
     unless (BROKEN_NONBLOCKING){
       fcntl($l, F_SETFL, O_NONBLOCK) 
        || die "can't set non blocking: $!";
     };
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
      # import Serve into caller's package
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

   if(DEBUG){
     print "Request:\n${_}END_REQUEST\n";
   };

   # defaults:
   %_=(Data => undef,
       ResultCode => 200);

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
   @_{qw/
      REQUEST_METHOD REQUEST_URI HTTPver RequestHeader
      REMOTE_ADDR/
   } = (
      $1,$2,$3,$4,
      $PeerAddr[$fn], 
   );
   if(DEBUG){for( sort keys %_ ){
      print "$_ is $_{$_}\n";
   }};

   # REQUEST_URI is
   # equivalent to SCRIPT_NAME . PATH_INFO . '?' . QUERY_STRING

   my $shortURI;
   ($shortURI ,$_{QUERY_STRING}) = $_{REQUEST_URI}=~m#(/[^\?]*)\??(.*)$#;
   $shortURI =~ s/%(..)/chr hex $1/ge; # RFC2616 sec. 3.2
   if (uc($_{REQUEST_METHOD}) eq 'POST'){
      $_{POST_DATA} = $PostData[$fn];
   };

   my @URIpath = split '/',$shortURI,-1; 
   my @Castoffs;
   my $mypath;
   while (@URIpath){
      $mypath = join '/',@URIpath;
      DEBUG and print "considering $mypath\n";
      if (exists $Path{$mypath}){
         $_{SCRIPT_NAME} = $mypath;
         print "PATH $mypath is $Path{$mypath}";
         $_{PATH_INFO} = join '/', @Castoffs;
         print " and PATH_INFO is $_{PATH_INFO}\n";
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
            my $FILE;
            my $filename = "$1/$_{PATH_INFO}";
            print "filename: $filename\n";
            $filename =~ s/\/\.\.\//\//g; # no ../../ attacks
            my ($ext) = $filename =~ /\.(\w+)$/;
            my $ContentType = $MimeType{$ext}||$DefaultMimeType;
            # unless (-f $filename and -r _ ){
            unless(open $FILE, "<", $filename){
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
            my $size = -s $filename;
            my $slurp;
            my $read = sysread $FILE, $slurp, $StaticBufferSize ;

            if ($read < $size){
               $LargeFile[$fn] = $FILE;
            };

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
      if((length $URIpath[$#URIpath]) > 0){
         unshift @Castoffs, pop @URIpath;
      }else{
         $URIpath[$#URIpath] = '/'
      };
   };


   $_{ResultCode} = 404;
   <<EOF;
Content-type:text/plain

$$ $RequestTally handling fileno $fn

apparently this Singlethreaded server does not
have a default handler installed at its 
virtual root.

Castoffs: [@Castoffs]

Responsible person: [$WebEmail]

$_

EOF

};


sub HandleRequest(){
   $RequestTally++;
   print "Handling request $RequestTally on fn $fn\n";
   # print "Inbuf:\n$inbuf[$fn]\n";
   *_ = \delete $inbuf[$fn]; # tight, huh?
   
   my $dispatchretval = dispatch;
   $dispatchretval or return undef;
   if($_{Data}){
   $outbuf[$fn]=<<EOF;  # change to .= if/when we support pipelining
HTTP/1.1 $_{ResultCode} $RCtext{$_{ResultCode}}
Server: $ServerType
$_{Data}
EOF
   };
   if(ref($dispatchretval)){
      my ($poll, $continue);
      if(ref($dispatchretval) eq 'ARRAY'){
         ($continue,$poll) = @{$dispatchretval}
      }elsif(ref($dispatchretval) eq 'HASH'){
         ($poll, $continue) = @{$dispatchretval}{qw/poll continue/}
      }else{
         die "I do not understand what to do with <<$dispatchretval>> here";
      }
      ref($poll) eq 'CODE' and $poll[$fn] = $poll;
      ref($continue) eq 'CODE' or die
         die "I do not understand what to do with <<$continue>> here";
      $continue[$fn] = $continue;

   }else{
         $outbuf[$fn]=<<EOF;  # change to .= if/when we support pipelining
HTTP/1.1 $_{ResultCode} $RCtext{$_{ResultCode}}
Server: $ServerType
$dispatchretval
EOF
   }

};

my $client_tally = 0;
sub Serve(){
   print "L: (@Listeners) C: (@Clients)\n";
   my ($rin,$win,$ein,$rout,$wout,$eout);
   my $nfound;

  # support for continuation coderefs to empty outbufs
  {
   my @PM;
   for $fn (@PollMe){
         if(
           defined($continue[$fn])
         ){
           if (defined $poll[$fn] and !&{$poll[$fn]}){
              push @PM, $fn;
              next;
           };
           $_{Data} = '';
           ($continue[$fn],$poll[$fn]) = &{$continue[$fn]};
           length( $outbuf[$fn] = $_{Data} )
              or push @PM, $fn;
         }
   };

   @PollMe = @PM;

  };

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
         my $paddr;
         vec($rout,fileno($_),1) or next;
         # relies on listeners being nonblocking
         # thanks, thecap
         # (at http://www.perlmonks.org/index.pl?node_id=6535)
         if (BROKEN_NONBLOCKING){ # this is a constant so the unused one
                                  # will be optimized away
          acc:
          $paddr=accept(my $NewServer, $_);
          if ($paddr){
            $fn =fileno($NewServer); 
            $inbuf[$fn] = $outbuf[$fn] = '';
            print "Accepted $NewServer (",
                  $fn,") ",
                  ++$client_tally,
                  "/$MaxClients on $_ ($fn) port $PortNo[fileno($_)]\n";
            push @Clients, $NewServer;

               my($port,$iaddr) = sockaddr_in($paddr);
               # $PeerAddr[$fn] = gethostbyaddr($iaddr,AF_INET);
               $PeerAddr[$fn] = inet_ntoa($iaddr);

          }
          # select again to see if there's another
          # client enqueued on $_
          my $rvec;
          vec($rvec,fileno($_),1) = 1;
          select($rvec,undef,undef,0);
          vec($rvec,fileno($_),1) and goto acc;
      
         }else{
          while ($paddr=accept(my $NewServer, $_)){
            $fn =fileno($NewServer); 
            $inbuf[$fn] = $outbuf[$fn] = '';
            print "Accepted $NewServer (",
                  $fn,") ",
                  ++$client_tally,
                  "/$MaxClients on $_ ($fn) port $PortNo[fileno($_)]\n";
            push @Clients, $NewServer;

               my($port,$iaddr) = sockaddr_in($paddr);
               # $PeerAddr[$fn] = gethostbyaddr($iaddr,AF_INET);
               $PeerAddr[$fn] = inet_ntoa($iaddr);
          }
         }
      }
   } # if accepting connections

   # Send outbound data from outbufs 
   my $wlen;
   for(@Outs){
      $fn = fileno($_);
      vec($wout,$fn,1) or next;
      $wlen = syswrite $_, $outbuf[$fn], length($outbuf[$fn]);
      if(defined $wlen){
        print "wrote $wlen of ",length($outbuf[$fn])," to ($fn)\n";
        substr $outbuf[$fn], 0, $wlen, '';
      
        # support for chunking large files (not HTTP1.1 chunking, just
        # reading as we go
        if(
           length($outbuf[$fn]) < $StaticBufferSize
        ){
         if(
           defined($LargeFile[$fn])
         ){
             my $slurp;
             my $read = sysread $LargeFile[$fn], $slurp, $StaticBufferSize ;
             # zero for EOF and undef on error
             if ($read){
               $outbuf[$fn].= $slurp; 
             }else{
                print "sysread error: $!" unless defined $read;
                delete $LargeFile[$fn];
             };
            };
         # support for continuation coderefs
         }elsif(
           defined($continue[$fn])
         ){
           if (defined $poll[$fn] and !&{$poll[$fn]}){
              length ($outbuf[$fn]) or push @PollMe, $fn;
              next;
           };
           ($continue[$fn],$poll[$fn]) = &{$continue[$fn]};
           $outbuf[$fn] .= $_{Data};
           length ($outbuf[$fn]) or push @PollMe, $fn;
           next;
         };
      }else{
         print "Error writing to socket $_ ($fn): $!\n";
         $outbuf[$fn] = '';
      }

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
                DEBUG and print "$fn: read [$char]\n";
		$inbuf[$fn] .= $char;
                # CompleteRequest or not?
                if($inbuf[$fn] =~
/^POST .*?Content-Length: ?(\d+)[\015\012]+(.*)$/is){
                   DEBUG and print "posting $1 bytes\n";
                   if(length $2 >= $1){
                      push @CompleteRequests, $fn;
                      $PostData[$fn] = $2;
                   }else{
                      if(DEBUG){
                       print "$fn: Waiting for $1 octets of POST data\n";
                       print "$fn: only have ",length($2),"\n";
                      }
                   }
		}elsif(substr($inbuf[$fn],-4,4) eq "\015\012\015\012"){
                   push @CompleteRequests, $fn;
                }elsif(DEBUG){
                   print "Waiting for request completion. So far have\n[",
                   $inbuf[$fn],"]\n";

                };   
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
  # configuration can also be provided in Use line.
  use HTTP::Server::Singlethreaded
     timeout => \$NotSetToAnythingForFullBlocking,
     function => { # must be a hash ref
                    '/time/' => sub {
                       "Content-type: text/plain\n\n".localtime
                    }
     },
     path => \%ChangeConfigurationWhileServingBySettingThis;
  #
  # "top level select loop" is invoked explicitly
  for(;;){
    #
    # manage keepalives on database handles
    if ((time - $lasttime) > 40){
       ...
       $lasttime = time;
    };
    # Auto restart on editing this file
    BEGIN{$OriginalM = -M $0}
    exec "perl -w $0" if -M $0 != $OriginalM;
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

=head3 $StaticBufferSize

How much of a large file do we read in at once?  Without memory 
mapping, we have to read in files, and then write them out. Files larger
than this will get this much read from them when the output buffer is
smaller than this size.  Defaults to 50000 bytes, so output buffers
for a request should fluctuate between zero and 100000 bytes while
serving a large file.

=head2 %Function

Paths to functions => functions to run.  The entire server request is
available in C<$_> and several variables are available in C<%_>.  C<$_{PATH_INFO}>,C<$_{QUERY_STRING}> are of interest. The whole standard CGI environment
will eventually appear in C<%_> for use by functions but it does not yet.

=head2 %CgiBin

CgiBin is a functional wrapper that forks and executes a named
executable program, after setting the common gateway interface
environment variables and changing
directory to the listed directory. NOT IMPLEMENTED YET

=head2 @Port

the C<@Port> array lists the ports the server tries to listen on.

=head2 name-based virtual hosts

not implemented yet; a few configuration interfaces are possible,
most likely a hash of host names that map to strings that will be
prepeneded to the key looked up in %Path, something like

   use HTTP::Server::Singlethreaded 
      vhost => {
         'perl.org' => perl =>
         'www.perl.org' => perl =>
         'web.perl.org' => perl =>
         'example.org' => exmpl =>
         'example.com' => exmpl =>
         'example.net' => exmpl =>
         'www.example.org' => exmpl =>
         'www.example.com' => exmpl =>
         'www.example.net' => exmpl =>
      },
      static => {
         '/' => '/var/web/htdocs/',
         'perl/' => '/var/vhosts/perl/htdocs',
         'exmpl/' => '/var/vhosts/example/htdocs'
      }
   ;

Please submit comments via rt.cpan.org.

=head2 $Timeout

the timeout for the select.  C<0> will cause C<Serve> to simply poll.
C<undef>, to cause Serve to block until thereis a connection, can only
be passed on the C<use> line.

=head2 $MaxClients

if we have more active clients than this we won't accept more. Since
we're not respecting keepalive at this time, this number indicates
how long of a backlog singlethreaded will maintain at any moment,and
should be orders of magnitude lower than the number of simultaneous
web page viewers possible. Depending on how long your functions take.

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
relevant lines in the module source if you need this. Forking after
initializing the module should work too.  This might get removed
as an example of featureitis.

=head2 $uid and $gid

when starting as root in a *nix, specify these numerically. The
process credentials will be changed after the listening sockets
are bound.

=head1 Dynamic Reconfiguration

Dynamic reconfiguration is possible, either by directly altering
the configuration variables or by passing references to import().

=head1 Action Selection Method

The request is split on slashes, then matched against the configuration
hash until there is a match.  Longer matching pieces trump shorter ones.

Having the same path listed in more than one of C<%Static>,
C<%Functions>, or C<%CgiBin> is
an error and the server will not start in that case. It will die
while constructing C<%Path>.

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

As of late 2004, Mozilla FireFox will show you error messages while
Microsoft Internet Explorer hides error messages from its users, at
least with the default configuration.

=head3 Data

Store your complete web page output into C<$_{Data}>, just as you
would write output starting with server headers when writing
a simple CGI program. Or leave $_{Data} alone and return a valid
page, beginning with headers.

=head1 AVOIDING DEADLOCKS

The server blocks while reading files and executing functions.

=head2 avoiding waiting  with callbacks

A way 
for a function to return immediately and specify a callback.

Instead of a string to send to the client, the function 
returns a coderef to indicate
that Singlethreaded needs to check back later to see if the page
is ready, by running the coderef, next time around.  Data for
the client, if any, must be stored in C<$_{Data}>.


Instead of a coderef, a hashref or an arrayref is acceptable.
The hashref needs to have 'continue' defined within it as a coderef.,
and may have 'poll' defined in it when it makes sense to have 
separate poll and continue coderefs.

=head3 poll

a reference to code that will return a boolean indicating true when it is time
to run the continue piece and get some data, or false when we should wait
some more before running the continuation.

=head3 continue

a coderef that, when run, will set $_{Data} with an empty or non-empty
string, and return a (contine, [poll]) list. 

=head2 an arrayref instead of a hashref

in the order of, C<[$continue, $poll]> so the later one
can be left out if there is no poll code.

=head2 example

Lets say we have two functions called C<Start()> and C<More($)> that
we are wrapping as a web service with Singlethreaded. C<Start> returns
a handle that is passed as an argument to C<More> to prevent instance
confusion.  C<More> will
return either some data or emptystring or undef when it is done.  Here's
how to wrap them:

   sub StartMoreWrapper{
      my $handle = Start or die "Start() failed";
      my $con;
      $_{Data} = <<EOF;
   Content-type: text/plain

   Here are the results from More:
   EOF

      $con = sub{
         my $rv = More($handle);
         if(defined $rv){
              $_{Data} = $rv;
              return ($con);
         };
         ();
      }
   }

And be sure to put C<'/startrestults/' => \&StartMoreWrapper> into the
functions hash.



=head1 What Singlethreaded is good for

Singlethreaded is designed to provide a web interface to a database,
leveraging a single persistent DBI handle into an unlimited number
of simultaneous HTTP requests.  

=head1 HISTORY

=over 8

=item 0.01

August 18-22, 2004.  %CgiBin is not yet implemented.

=item 0.02

August 22, 2004.  Nonblocking sockets apparently just
plain don't exist on Microsoft Windows, so on that platform
we can only add one new client from each listener on each
call to serve. Which should make no difference at all. At least
not noticeable. The connection time will be longer for some of
the clients in a burst of simultaneous connections.  Writing
around this would not be hard: another select loop that only
cares about the Listeners would do it.

=item 0.03

The listen queue will now be drained until empty on platforms
without nonblocking listen sockets thanks to a second C<select>
call.

Large files are now read in pieces instead of being slurped whole.

=item 0.04

Support for continuations for page generating functions is in place.

=item 0.05

Support for POST data is in place. POST data appears in C<$_{POST_DATA}>.
Other CGI variables now available in C<%_> include PATH_INFO, QUERY_STRING, REMOTE_ADDR, REQUEST_METHOD, REQUEST_URI and SCRIPT_NAME.

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
