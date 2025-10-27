#!/opt/local/bin/perl -Tw

# Converts a hex-dumped PsiGar .trk file to a GPX file.

use XML::LibXML;
use Time::Local;
use HTTP::Date qw/time2isoz/;

use constant Pid_Xfer_Cmplt	=> 12;
use constant Pid_Nack		=> 21;
use constant Pid_Trk_Hdr 	=> 99;
use constant Pid_Trk_Data 	=> 34;

use constant XSI_URI  => 'http://www.w3.org/2001/XMLSchema-instance';
use constant GPX_URI  => 'http://www.topografix.com/GPX/1/1';
use constant GPXX_URI => 'http://www.garmin.com/xmlschemas/GpxExtensions/v3';

use constant CREATOR_URI => 'http://ns.angellane.org/psigar-to-gpx';

my $doc = XML::LibXML::Document->new();

my $root = $doc->createElementNS(GPX_URI, 'gpx');
$doc->setDocumentElement($root);

$root->setNamespace(GPXX_URI, 'gpxx', 0);
$root->setNamespace(XSI_URI, 'xsi', 0);
$root->setAttribute('version', '1.1');
$root->setAttribute('creator', CREATOR_URI);
$root->setAttributeNS(XSI_URI, 'schemaLocation',
		      join ' ', GPX_URI, 'http://www.topografix.com');

my $metad = $doc->createElement('metadata');
my $track = $doc->createElement('trk');

$root->addChild($metad);
$root->addChild($track);


my $trk_seg = undef;

my $min_lon = 400;
my $min_lat = 400;
my $max_lon = -400;
my $max_lat = -400;

while (<>) {
    s/ //g;
    my $object = pack 'H*', />(.*?)</;

    # $object is record Pid, reclen, data, checksum (i.e. byte numbers
    # 1 to n-3 in the Garmin IntfSpec.pdf. DLE-destuffing has already
    # occurred.
    #
    # Example:
    #  >22 0D 80 B2 96 24 C0 89 46 00 37 A3 9B 13 01 CD<

    my ($rectype, $datalen, $data) = unpack ('CCa*', $object);
    $data =~ /^(.*)(.)$/s;
    $data = $1;
    my $checksum = ord $2;

    # Checksum is twos complement of $rectype, $datalen and $data.
    # So if we sum those bytes *and* the checkdum we should get a
    # value that's divisible by 256.

    my $sum = 0;
    foreach my $byte (unpack 'C*', $object) {
	$sum += $byte;
    }

    if ($sum % 256) {
	print STDERR "Ignoring record with invalid checksum.\n";
    }
    elsif ($datalen != length $data) {
	print STDERR "Record length wrong: got $datalen, should be ", 
			length $data, "\n";
    }
    elsif ($rectype == Pid_Nack) { 
	# ignore
    }
    elsif ($rectype == Pid_Xfer_Cmplt) {
	# ignore
    }
    elsif ($rectype == Pid_Trk_Hdr) {	# Assume D310
	# typedef struct
	# {
	#   bool dspl; /* display on the map? */
	#   uint8 color; /* color (same as D108) */
	#/* char trk_ident[];    null-terminated string */
        # } D310_Trk_Hdr_Type;

	# >63 0D/01/FF/41 43 54 49 56 45 20 4C 4F 47 00/D2<  c...ACTIVE LOG..

	my ($dspl, $colour, $ident)
	    = unpack 'CCZ*', $data;
	
	$track->addChild($doc->createElement('name'))->appendText($ident);

	# Colours, cf D108
	%colour_map = ( 0 => "Black",	        1 => "DarkRed",
		        2 => "DarkGreen",       3 => "DarkYellow",
		        4 => "DarkBlue",        5 => "DarkMagenta",
		        6 => "DarkCyan",        7 => "LightGray",
		        8 => "DarkGray",        9 => "Red",
		       10 => "Green",	       11 => "Yellow",
		       12 => "Blue",	       13 => "Magenta",
		       14 => "Cyan",	       15 => "White",
	    );

	$colour = exists $colour_map{$colour} ? $colour_map{$colour} : undef;
	$colour = 'Transparent' unless $dspl;

	if (defined $colour) {
	    my $x  = $doc->createElement('extensions');
	    my $tx = $doc->createElementNS(GPXX_URI, 
					   'TrackExtension');
	    $track->addChild($x);
	    $x->addChild($tx);
	    
	    $tx->addChild($doc->createElement('DisplayColor'))
		->appendText($colour);
	}
    }
    elsif ($rectype == Pid_Trk_Data) {
	if (13 == $datalen) {		# D300 GPS 45 XL track point

	    # typedef struct
	    # {
	    #    position_type posn; /* position */
	    #    time_type time; /* time */
	    #    bool new_trk; /* new track segment? */
	    # } D300_Trk_Point_Type;

	    my ($posn_lat, $posn_lon, $time, $new_trk)
		= unpack('VVVC', $data);

	    # Unsigned semicircles to signed degrees
	    $posn_lat = unpack('l', pack 'L', $posn_lat) * 180.0 / (2**31);
	    $posn_lon = unpack('l', pack 'L', $posn_lon) * 180.0 / (2**31);

	    # Time is offset from 1989-12-31 00:00
	    # E.G. 2000-06-03 11:42:47 is 0x37 a3 9b 13
	    $time += timegm(0,0,0,31,11,89);

	    $trk_seg = undef		if $new_trk;
	    $track->addChild($trk_seg = $doc->createElement('trkseg'))
					unless defined $trk_seg;

	    my $trk_point = $doc->createElement('trkpt');
	    $trk_seg->addChild($trk_point);

	    $trk_point->setAttribute('lat',  $posn_lat);
	    $trk_point->setAttribute('lon', $posn_lon);
	    $trk_point->setAttribute('time', time2isoz($time));

	    $min_lon = $posn_lon if $posn_lon < $min_lon;
	    $min_lat = $posn_lat if $posn_lat < $min_lat;
	    $max_lon = $posn_lon if $posn_lon > $max_lon;
	    $max_lat = $posn_lat if $posn_lat > $max_lat;
	}
	elsif (27 == length $object) {	# D302 eTrex Vista track point

	    # typedef struct
	    # {
	    #   position_type posn; /* position */
	    #   time_type time; /* time */
	    #   float32 alt; /* altitude in meters */
	    #   float32 dpth; /* depth in meters */
	    #   bool  new_trk; /* new track segment? */
	    # } D301_Trk_Point_Type;

	    # >22 18/00 3C CB 23,00 61 B4 FC/89 C5 47 21/
	    #        80 51 14 41/51 59 04 69/01/FF FF FF/9A<

	    my ($posn_lat, $posn_lon, $time, $alt, $dpth, $new_trk)
		= unpack('VVVVVC', $data);

	    # Unsigned semicircles to signed degrees
	    $posn_lat = unpack('l', pack 'L', $posn_lat) * 180.0 / (2**31);
	    $posn_lon = unpack('l', pack 'L', $posn_lon) * 180.0 / (2**31);

	    # Time is offset from 1989-12-31 00:00
	    # E.G. 2000-06-03 11:42:47 is 0x37 a3 9b 13
	    $time += timegm(0,0,0,31,11,89);

	    # These are single precision floats, packed in VAX order
	    $alt  = unpack ('f', pack 'L', $alt);
	    $dpth = unpack ('f', pack 'L', $dpth);

	    $trk_seg = undef		if $new_trk;
	    $track->addChild($trk_seg = $doc->createElement('trkseg'))
					unless defined $trk_seg;

	    my $trk_point = $doc->createElement('trkpt');
	    $trk_seg->addChild($trk_point);

	    $trk_point->setAttribute('lat',  $posn_lat);
	    $trk_point->setAttribute('lon', $posn_lon);
	    $trk_point->setAttribute('ele', $alt);
	    $trk_point->setAttribute('time', time2isoz($time));

	    $min_lon = $posn_lon if $posn_lon < $min_lon;
	    $min_lat = $posn_lat if $posn_lat < $min_lat;
	    $max_lon = $posn_lon if $posn_lon > $max_lon;
	    $max_lat = $posn_lat if $posn_lat > $max_lat;

	    # Spec says this value is meaningless if equal to
	    # 1.0e25. In practice we see that as 9.99999956202353e24
	    # so use a slightly different condition.
	    $dpth = undef if $dpth > 9.9e24;

	    # The remaining fields aren't in GPX; they're in the
	    # Garmin GPX Extensions
	    
	    if (defined($dpth)) {
		my $x  = $doc->createElement('extensions');
		my $tx = $doc->createElementNS(GPXX_URI, 
					       'TrackpointExtension');
		$trk_point->addChild($x);
		$x->addChild($tx);
		
		$tx->addChild($doc->createElement('Depth'))
		    ->appendText($dpth)		if defined $dpth;
	    }
	}
	else {
	    print STDERR "Unknown length ", length $object, "\n"
	}
    }
    else {
	print STDERR "Unknown record type $rectype ignored\n";
    }
}

my $bounds = $doc->createElement('bounds');
$metad->addChild($bounds);
$bounds->setAttribute('minlat', $min_lat);
$bounds->setAttribute('minlon', $min_lon);
$bounds->setAttribute('maxlat', $max_lat);
$bounds->setAttribute('maxlon', $max_lon);

print $doc->toString(1)
