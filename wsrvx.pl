#!/usr/bin/perl -w
# History
# 2008/02/04 adopted singular name wsrx.pl
use IO::Socket;
use Net::hostent;
# for OO version of gethostbyaddr
use strict;


# main globals
my $FLAG_SHOWHIDDEN = 0;
my $FLAG_USEWIKI    = 0;
my $FLAG_CGI        = 0;
my $PORT            = 9000;
my  $VERSION = '13.11.19';
my %param;
$param{'_SERVER'}{'HTTPS'}='on';
$param{'_SERVER'}{'GATEWAY_INTERFACE'} = 'CGI/1.1';
$param{'_SERVER'}{'HTTP_ACCEPT'}='image/gif, image/x-xbitmap, image/jpeg, image/pjpeg, */*';
$param{'_SERVER'}{'HTTP_ACCEPT_CHARSET'}='iso-8859-1,*,utf-8';
$param{'_SERVER'}{'HTTP_ACCEPT_LANGUAGE'}='en';
$param{'_SERVER'}{'SERVER_SOFTWARE'}="WSRVX $VERSION";
$param{'_SERVER'}{'SERVER_ADMIN'} = 'adminguy@acme.com';
$param{'_SERVER'}{'SERVER_NAME'} = 'coyote.acme.com';
$param{'_SERVER'}{'SERVER_PROTOCOL'} = 'HTTP/1.0';
$param{'_SERVER'}{'DEBUG'} = '1';


=comment

DOCUMENT_ROOT = /usr/local/etc/apache/htdocs
GATEWAY_INTERFACE = CGI/1.1
   HTTP_ACCEPT = image/gif, image/x-xbitmap, image/jpeg, image/pjpeg, */*
   HTTP_ACCEPT_CHARSET = iso-8859-1,*,utf-8
   HTTP_ACCEPT_LANGUAGE = en
   HTTP_CONNECTION = Keep-Alive
   HTTP_HOST = 200.210.220.1:8080
   HTTP_USER_AGENT = Mozilla/4.01 [en] (Win95; I)
   PATH = /usr/local/bin:/bin:/etc:/usr/bin
   QUERY_STRING = 
   REMOTE_ADDR = 200.210.220.3
   REMOTE_HOST = 200.210.220.3
   REMOTE_PORT = 1029
   REQUEST_METHOD = GET
   REQUEST_URI = /cgi-bin/utils/printenv.cgi
   SCRIPT_FILENAME = /usr/local/lib/apache/cgi-bin/utils/printenv.cgi
   SCRIPT_NAME = /cgi-bin/utils/printenv.cgi
   SERVER_ADMIN = adminguy@acme.com
   SERVER_NAME = coyote.acme.com
   SERVER_PORT = 8080
   SERVER_PROTOCOL = HTTP/1.0
   SERVER_SOFTWARE = Apache/1.2.5
   TZ = :US/Eastern 

=cut

# other convinience globals
my $ROOT=glob(".");
my $client;
my $mark=0;
sub debug() {
	return unless $param{'_SERVER'}{'DEBUG'};
	my ($mesg)=@_;
	$mesg.='';
	printf STDERR ("MARK %d : %s\n",$mark++,$mesg); 
}

sub printusage() {
	print STDERR "$0\n";
	print STDERR "Usage:\n";
	print STDERR "$0 [--port <port>] [--root <path>] [--wiki] [--cgi <.ext>]\n";
	print STDERR "\n";
	print STDERR "\n";
}

sub main() {
	while ($_ = shift @ARGV) {
		if ($_ eq '--port' and @ARGV) {
			$PORT=shift @ARGV;
		} elsif ($_ eq '--root' and @ARGV) {
			$ROOT= shift @ARGV;
		} elsif ($_ eq '--wiki') {
			$FLAG_USEWIKI=1;
		} elsif ($_ eq '--help' or $_ eq '-h') {
			&printusage();exit(0);
		} elsif ($_ eq '--cgi' and @ARGV) {
			$FLAG_CGI=shift @ARGV;
		}
	}

	die("Can't change dir to $ROOT\n") unless -d glob($ROOT) && chdir($ROOT);
	$param{'_SERVER'}{'DOCUMENT_ROOT'}=$ENV{PWD};
	$param{'_SERVER'}{'SERVER_PORT'}=$PORT;

	my $server = IO::Socket::INET->new( Proto     => 'tcp',
		LocalPort => $PORT,
		Listen    => SOMAXCONN,
		Reuse     => 1);

	die "can't setup server" unless $server;
	print "[Server $0 accepting clients at http://localhost:$PORT/]\n";

	while ($client = $server->accept()) {
		my $pid = fork();
		die "Cannot fork" unless defined $pid;
		if ($pid) { #parent
			close $client;
			next;
		}
		else { #child
			&doChildWork();
		}
	}
}


sub doChildWork() {
	$client->autoflush(1);
	&debug("Processing new connection");	
	my ($file, $cgiParams) = &getFileAndCGIParams();
	$param{'_SERVER'}{'HTTP_HOST'}=$client->sockhost();
	$param{'_SERVER'}{'REMOTE_HOST'}=$client->peerhost();
	$ENV{'HTTP_HOST'}=$param{'_SERVER'}{'HTTP_HOST'};
	$ENV{'REMOTE_HOST'}=$param{'_SERVER'}{'REMOTE_HOST'};
	$ENV{'QUERY_STRING'}=$param{'_SERVER'}{'QUERY_STRING'};
	$ENV{'REQUEST_METHOD'}=$param{'_SERVER'}{'REQUEST_METHOD'};
	$ENV{'PATH_INFO'}=$param{'_SERVER'}{'SCRIPT_URL'};
	$ENV{'PATH_TRANSLATED'}=$param{'_SERVER'}{'DOCUMENT_ROOT'} . $param{'_SERVER'}{'SCRIPT_URL'};
	$ENV{'SCRIPT_NAME'}=$param{'_SERVER'}{'SCRIPT_URL'};
	
	foreach my $key (keys %{$param{'_SERVER'}}){
		&debug("SERVER $key:$param{'_SERVER'}{$key}");
	}
	foreach my $key (keys %{$param{'_CLIENT'}}){
		&debug("CLIENT $key:$param{'_CLIENT'}{$key}");
	}
	&sendError(404, ('file',$file)) unless  -e "$file" ;
	&sendError(503,('file', $file)) unless  -r "$file" ;
	
	if (-d $file) {
		&processDir($file);
	}

	elsif (-f $file ) {
		if ($FLAG_CGI && $file =~ m/$FLAG_CGI$/) {
			&processCGIFile($cgiParams, $file);
		}
		else {
			if ($FLAG_USEWIKI && $file =~ m/\.wiki/) {
				&sendFileAsWikiPage($file);	
			}
			else {
				&sendFileBasic($file);
			}
		}
	}
	
	close $client;
}

sub wikifyLine() {
	my ($line) = @_;
	$line =~ s#^\={3,3}(.*)$#<H3>$1</H3>#;
	$line =~ s#^\={2,2}(.*)$#<H2>$1</H2>#;
	$line =~ s#^\=(.*)$#<H1>$1</H1>#;
	$line =~ s#^\*(.*)#<li>$1</li>#;
	$line =~ s#^-$#<hr>#;
	$line =~ s#<<(.*?)>>#<IMG SRC="$1">#g;
	$line =~ s#\[\[(.*?)\]\[(.*)\]\]#<a href="$1">$2</a>#g;
	return $line;
}
sub serverinfo(){
	my $mime= "text/html";
        print $client "HTTP/1.0 200 OK\nContent-Type: $mime\n\n";
	print $client "<h2>Server info</h2><br/>\n";
	print $client "<table border=1>\n\t<tr><td bgcolor=aaaadd>variable</td><td bgcolor=aaaaff>value</td></tr>";
	foreach my $key (keys %{$param{'_SERVER'}}){
                &debug("SERVER $key:$param{'_SERVER'}{$key}");
		print $client "\n\t<tr><td bgcolor=aaaaaa>$key</td><td>$param{'_SERVER'}{$key}</td></tr>";
        }
	print $client "\n</TABLE>\n";
	print $client "<h2>Client info</h2><br/>\n";
	print $client "<table border=1>\n\t<tr><td bgcolor=aaaadd>variable</td><td bgcolor=aaaaff>value</td></tr>";
	foreach my $key (keys %{$param{'_CLIENT'}}){
                &debug("CLIENT $key:$param{'_CLIENT'}{$key}");
		print $client "\n\t<tr><td bgcolor=aaaaaa>$key</td><td>$param{'_CLIENT'}{$key}</td></tr>";
        }
	print $client "\n</TABLE>\n";
	exit(0);
}

sub getFileAndCGIParams() {
	my $request = <$client>;
	&debug("REQUEST: $request");
	&sendError(400) unless $request =~ m{^(GET|POST)\s(/\S*) HTTP/1.[0|1]};
	my $method=$1;
	$param{'_SERVER'}{'REQUEST_METHOD'}=$method;
	my $urirequest = $2;
	my $file="$2";

	my $cgiParams='';
	$param{'_SERVER'}{'QUERY_STRING'}=$cgiParams;
	if ($urirequest=~ m/(.+)\?(.+)/) {
		$file="$1";
		#$cgiParams=$2;
		$cgiParams=substr($2,0,1024);
		$param{'_SERVER'}{'QUERY_STRING'}=$cgiParams;
		foreach (split ("&",$2)) {
			my ($key,$val) = split ("=",$_);
			$val=&querystring2plain($val);
			$param{'_CLIENT'}{$key}=$val;
		}
	}
	$file=&uri2plain($file);
	$param{'_SERVER'}{'SCRIPT_URL'}=$file;
	$param{'_SERVER'}{'REQUEST_URI'}=$urirequest;
	&serverinfo() if $file eq '/serverinfo';
	&debug("$method $file");
	return (".$file", $cgiParams);
}

sub querystring2plain() {
	my ($val)=@_;
	$val=~ s/\+/ /g;
	$val=~ s/%([0-9A-Fa-f]{2,2})/chr(hex($1))/eg;
	return $val;
}


sub uri2plain() {
	my ($file)=@_;
	$file=~ s/%([0-9A-Fa-f]{2,2})/chr(hex($1))/eg;
	return $file
}

sub plain2uri() {
	my ($file)=@_;
	$file=~ s/([^A-Za-z0-9-\.\/])/"%" .sprintf( "%0x", ord($1));/eg;
	return $file

}

sub plain2unixpath() {
	my ($file)=@_;
	$file=~ s/([ ])/\\$1/g;
	return $file
}

sub unixpath2plain() {
	my ($file)=@_;
	$file=~ s/\\(.)/$1/g;
	return $file
}
sub sendFileBasic() {
	my ($file) = @_;
	my $unixfile=&plain2unixpath($file);
	
	#my $mime= `file -bi $unixfile`;
	my $mime= `file -i $unixfile`;
	$mime=~s/.*(\S+)$/$1/;
	chomp $mime;
	
	&sendOKHeader($mime);
	open(FILE,$file);
	while (<FILE>) {
		print $client $_;
	}
	close FILE;
}

sub sendFileAsWikiPage() {
	my ($file) = @_;
	&sendOKHeader();
	print $client
		"<html>\n".
			"<head>\n<title>$file</title>\n<head>\n".
				"<body>\n";

	open(FILE,$file);
	while (<FILE>) {
		print $client &wikifyLine($_), "</BR>\n";
	}
	close FILE;

	print $client "</body>\n<html>";
}

sub processDir() {
	my ($dir) = @_;

	unless ($dir =~ m{/$}) {
		$dir=~ s/^\.//;
		&redir ("$dir/") unless $dir=~ m{/$};
	}
	if (-f "$dir/index.htm") {
		$dir=~ s/^\.//;
		&redir("${dir}index.htm");
	}
	&showdir($dir);
}

sub processCGIFile() {
	my ($cgiParams, $file) = @_;

	#&sendOKHeader();
	foreach my $key (keys %{$param{'_SERVER'}}){
		$ENV{$key}=$param{'_SERVER'}{$key};
	}
	open(my $f, "$file |") ||  &sendError(501, ('exit' => 1)); 
	print $client "HTTP/1.0 200 OK\n";
	print $client "Content-Type: text/html\n\n";
	while (<$f>) {
		print $client $_;
	}
	close $client;
}


sub processFile() {
	my ($file) = @_;

	if (-d $file) {
		unless ($file=~ m{/$}) {
			$file=~ s/^\.//;
			redir ("$file/") unless $file=~ m{/$};
		}
		&showdir($file);
	} elsif (-f $file) {
		my $mime= "text/html";
		chomp $mime;
		open(FILE,$file);
		print $client "HTTP/1.0 200 OK\nContent-Type: $mime\n\n";
		while (<FILE>) {
			print $client $_;
		}
		close(FILE);
	}
}

	
sub sendError(){
	my ($errorcode,%extended)=@_;
	if ($errorcode == 501){
		&debug("501. SERVER ERROR");
		&sendHttpHeader(501, "SERVER ERROR");
		&sendErrorBody("501. SERVER ERROR\n", 1);
	}elsif ($errorcode == 400){
		&debug("400. BAD REQUEST");
		&sendHttpHeader(400, "BAD REQUEST");
		&sendErrorBody("400. BAD REQUEST\n");
	}elsif ($errorcode == 404){
		&debug("File not found");
		&sendHttpHeader(404, "FILE NOT FOUND");
		&sendErrorBody("404. FILE NOT FOUND\n");
	}else {
		 &debug("$errorcode $extended{mesg}");
		&sendHttpHeader($errorcode, $extended{header});
		&sendErrorBody($errorcode . ". $extended{mesg}");
	}
	exit ($extended{'exit'}) if defined($extended{'exit'});
}

sub redir(){
	my ($uri)=@_;
	print $client "HTTP/1.0 301 Moved Permanently\n";
	print $client "Location: $uri\n\n";
	&sendErrorBody();
}

sub sendOKHeader() {
	my ($outType) = @_;
	if(not defined($outType)) {
		$outType = "text/html";
	}
	&sendHttpHeader(200, "OK", $outType);
}

sub sendHttpHeader() {
	my ($msgCode, $msgType, $outType) = @_;
	if(not defined($outType)) {
		$outType = "text/html";
	}
	print $client "HTTP/1.0 $msgCode $msgType\n";
	print $client "Content-Type: $outType\n\n";
}

sub sendErrorBody() {
	my ($msg, $exitCode) = @_;
	if (not defined($exitCode)) {
		$exitCode = 0;
	}
	if (defined($msg)) {
		print $client $msg;
	}
	close $client;
	exit( $exitCode );
}

sub showdir() {
	my ($dir)=@_;
	&debug("Accessing $dir");
	opendir(DIR,$dir) || &servererror("HTTP/1.0 501 SERVER ERROR");
	print $client "HTTP/1.0 200 OK\n";
	print $client "Content-Type: text/html\n\n";
	my @contentdir;
	my @contentfile;
	while ($_=readdir(DIR)) {
		next if $_ =~ m/^\.$/;
		if ($_=~ m/^\.\.$/) {
			push @contentdir,$_ if $_=~ m/^\.\.$/;
			next;
		}
		next if $_ =~ m/^\./ and not $FLAG_SHOWHIDDEN;
		if ( -d "$dir/$_" ) {
			push @contentdir, $_;
		} else {
			push @contentfile, $_;
		}
	}
	close(DIR);
	foreach (sort @contentdir) {
		my $lnk="<a href='". &plain2uri($_) ."'>[ $_ ]</a>";
		print $client "$lnk</br>\n";
		&debug("lnk: $_ -> ". &plain2uri($_));
	}

	my $icon;
	foreach (sort @contentfile) {
		if (-l "$dir/$_" ) {
			$icon="l";
		} else {
			$icon="f";
		}
		my $lnk="<a href='" .&plain2uri($_) ."'>$_</a>";
		print $client "$lnk</br>\n";
		&debug("lnk: $_ -> ". &plain2uri($_));
	}

	close($client);
	exit(0);
}


&main();
