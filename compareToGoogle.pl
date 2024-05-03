#!/usr/bin/perl -w
#
# Attempt to find list of files in an archive directory that are not in Google Photos
#
# Prerequisite : download all files from Google Photos via takeout
# 
# Google files can be tricky since they may be compressed or otherwise manipulated
use strict;
use Cwd qw(getcwd);
use Getopt::Long;
## cp keeps timestamp?
use File::Copy "cp";
use Data::Dumper;
use File::Basename qw/dirname/;
my $valid_photo_extensions = "AVIF, BMP, GIF, HEIC, ICO, JPG, PNG, TIFF, WEBP, RAW";
my $valid_video_extensions ="3GP, 3G2, ASF, AVI, DIVX, M2T, M2TS, M4V, MKV, MMV, MOD, MOV, MP4, MPG, MTS, TOD, WMV";
my @extensions = map {s/^\s*/\./; s/\s*$//; $_} split (/,/,"$valid_photo_extensions,$valid_video_extensions");
my $extensionsRegex = join ('$|',@extensions).'$';



my %options=();

$options{'takeout-list'} = 'takeoutlist.txt';
$options{'photos-list'} = 'photoslist.txt';
GetOptions (\%options,qw(--compare --make-list --takeout-dir=s --photos-dir=s --takeout-list=s --photos-list=s -h --help --include-all --copy-photos-to-dir=s --copy-takeout-to-dir=s --just-photos --print-same));

if ($options{"h"} || $options{'help'}) {
	show_help();
}

sub show_help {
	print <<EOF1;
compareToGoogle.pl
Find duplicate images and organize library
Jeremy Hubble April 28, 2024

--compare		Compare files ; If  dir is specified and list does not exist, filelist will be created
--make-list		Create filelist (via exiftool)
--photos-dir dir	fingerprint file output using jdupes
--takeout-dir dir	dup file
--photos-list file	directory to do searches (default $options{'photos-list'})
--takeout-list file	directory where data files (filelists, etc.) are located (default $options{'takeout-list'})
--include-all		default is false. Include all files in comparison if set. Otherwise, only include valid google photos extensions
		photo extensions: $valid_photo_extensions
		video extensions: $valid_video_extensions
--copy-photos-to-dir dir	Copy photos not in takeout to directory tree
--copy-takeout-to-dir dir	Copy takeout files not in photos to diectory tree
--just-photos		just check to see if takeout items are missing from photos (default false)
--print-same		print items the same in both (default false)
-help			print help
-h			print help

Examples:

# compare the photo library to google files
# It will create filelists and do comparisons
# Making filelists can take a long time
compareToGoogle.pl --compare --photos-dir /pathToPhotos --takeout-dir /pathToGoogleTakeoutFiles

# make the exiflist of files (for comparison later)
compareToGoogle.pl --make-list --photos-list filelist.txt --photos-dir /pathToPhotosOrGoogle

# compare the files based on created list
compareToGoogle.pl --compare --photos-list photoslist.txt --takeout-list takeoutlist.txt
EOF1

print <<'EOF1';
# a commandline to manuall generate the list from a list of files
cat newFiles.txt|xargs -L 1 -I% exiftool -fast -fast2 -f -p '$DateTimeOriginal    $directory/$filename    $FileSize#      $ImageWidth
$ImageHeight    $DocumentName#' % >> myList.txt
EOF1

exit();
}

if ($options{"make-list"} || $options{compare}) {
	# only make new list if we don't have list, or we have been explicitly asked
	if ($options{'takeout-dir'} && ($options{'make-list'} || !-f $options{'takeout-list'})) {
		&create_exif_list($options{'takeout-dir'}, $options{'takeout-list'});
	}
	if ($options{'photos-dir'} && ($options{'make-list'} || !-f $options{'photos-list'})) {
		&create_exif_list($options{'photos-dir'}, $options{'photos-list'});
	}
}
else {
	show_help();
}

my %takeoutNameIndex;
my %photoNameIndex;

my %takeoutTimeIndex;
my %photoTimeIndex;

if ($options{"compare"}) {
	print "TAKEOUT LIST: ",$options{'takeout-list'},"\n";
	print "PHOTO LIST  : ",$options{'photos-list'},"\n";

	## start with a simple name compare
	my $takeoutRef = buildNameHash($options{'takeout-list'});
	%takeoutNameIndex = %{$takeoutRef};
	my $photoRef = buildNameHash($options{'photos-list'});
	%photoNameIndex = %{$photoRef};

	my $takeoutTimeRef = buildTimeHash($options{'takeout-list'});
	%takeoutTimeIndex = %{$takeoutTimeRef};
	my $photoTimeRef = buildTimeHash($options{'photos-list'});
	%photoTimeIndex = %{$photoTimeRef};

	if ($options{'copy-photos-to-dir'}) {
		print "COPYING missing photos to: $options{'copy-photos-to-dir'}\n";
	}
	if ($options{'copy-takeout-to-dir'}) {
		print "COPYING missing photos to: $options{'copy-takeout-to-dir'}\n";
	}

	my ($not_in_photos, $different_in_photos, $same_in_photos, $photo_time_exists) = compareNameLists(\%takeoutNameIndex, \%photoNameIndex, $options{'copy-takeout-to-dir'}, \%takeoutTimeIndex, \%photoTimeIndex);
	my ($not_in_takeout,$x,$y,$takeout_time_exists) = compareNameLists(\%photoNameIndex, \%takeoutNameIndex, $options{'copy-photos-to-dir'}, \%photoTimeIndex, \%takeoutTimeIndex);

	my $not_photos = scalar @$not_in_photos;
	my $not_photos_but_time = scalar @$photo_time_exists;
	my $not_takeout = scalar @$not_in_takeout;
	my $not_takeout_but_time = scalar @$takeout_time_exists;
	my $same_count = scalar @$same_in_photos;
	my $diff_count = scalar @$different_in_photos;

	print "\nNot in photos:\n",join("\n",map {"TKT:\t$takeoutNameIndex{$_}[0]"} @$not_in_photos),"\n";
	print "\n====================================================================\n";
	if (!$options{'just-photos'}) {
		print "\nNot in takeout:\n",join("\n",map {"PHT:\t$photoNameIndex{$_}[0]"} @$not_in_takeout),"\n";
		print "\n====================================================================\n";
	}
	print "\nNot in photos, but items with same times in photos\n";
	map { &printSameTimes($_) } @$photo_time_exists;
	print "\n====================================================================\n";
	if (!$options{'just-photos'}) {
		print "\nNot in takeout, but items with same times in takeout\n";
		map { &printSameTimes($_) } @$takeout_time_exists;
		print "\n====================================================================\n";
	}
	if ($options{'print-same'}) {
		print "\n====================================================================\n";
		print "\nSame filename found in both\n";
		print join("\n",map {"SME:\t$photoNameIndex{$_}[0]"} @$same_in_photos),"\n";
	}
	print <<EOF1;
	Not in photos :             $not_photos
	  - but some matching time: $not_photos_but_time
	Not in takeout:             $not_takeout
	  - but some matching time: $not_takeout_but_time
	Same name, different count: $diff_count
	Same name, same count     : $same_count
EOF1
}


sub printSameTimes {
	my ($index) = @_;
	my $photoElem = $photoNameIndex{$index};
	my $takeoutElem = $takeoutNameIndex{$index};
	my $count =0;

	if ($photoElem) {
		my @photoArray = @$photoElem;
		foreach my $elem (@photoArray) {
			$count += findSameTime($index, $elem, \%takeoutTimeIndex);	
		}
	}
	if ($takeoutElem) {
		my @takeoutArray = @$takeoutElem;
		foreach my $elem (@takeoutArray) {
			$count += findSameTime($index, $elem, \%photoTimeIndex);	
		}

	}
	if ($count == 0) {
		print "MATCHLESS: $index\n";
	}
}

sub findSameTime {
	my ($key, $baseItemInfo, $hashRef) = @_;
	my $count = 0;
	my %timeIndex = %$hashRef;
	my ($obname,$ots, $ofname, $osize, $owidth, $oheight) = split /\t/, $baseItemInfo;
	if ($ots eq '-') {
		return 0;
	}
	if (exists $timeIndex{$ots}) {
		my @timeArr = @{$timeIndex{$ots}};
		foreach my $itemInfo (@timeArr) {
			my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $itemInfo;
			if ($size == $osize) {
				print "SIZE MATCH:\n   SRC:\t$baseItemInfo\n   DST:\t$itemInfo\n";
				$count++;
			}
		}
	}
	return $count;
}


# compare two lists.
# Arguments:
#   list1
#   list2
#   optional directory to copy items that are not in list 2
sub compareNameLists  {
	my @lists = @_;
	my %list1 = %{$lists[0]};
	my %list2 = %{$lists[1]};
	my $copy_target = $lists[2];
	my %dateList1 = %{$lists[3]};
	my %dateList2 = %{$lists[4]};
	my @not_in_second;
	my @same_in_second;
	my @different_in_second;
	my @time_exists;
	foreach my $index (keys %list1) {
		## only process non-json files unless otherwise specified
		if ($options{'include-all'} || $index =~ /$extensionsRegex/i) {
			if (exists $list2{$index}) {
				if (compareArrays($list1{$index}, $list2{$index})) {
					push @same_in_second, $index;
				}
				else {
					push @different_in_second, $index;
				}

			}
			else {
				push @not_in_second, $index;
				my $itemInfo = $list1{$index}[0];
				my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $itemInfo;
				if (exists $dateList2{$ts}) {
					push @time_exists, $index;
				}

				if ($copy_target) {
					copyToTree($copy_target, $list1{$index}[0]);
				}
			}
		}
	}
	return (\@not_in_second, \@different_in_second, \@same_in_second,\@time_exists);
}
sub compareArrays {
	my ($arr1, $arr2) = @_;
	my @array1 = $arr1;
	my @array2 = $arr2;
	my %count;

	## TODO: use a more robust compare. For now, just compares the length
	
	if ($#array1 != $#array2) {
		return 0;
	}
	return 1;
}

sub create_exif_list() {
	my ($path, $OUTFILE) = @_;
	print "==== Creating exiftool list =====\n";
	print "Directory:   $path\n";
	print "Output path: $OUTFILE\n";
	open F, ">$OUTFILE";
	print F `exiftool -fast -fast2 -f -p '\$DateTimeOriginal	\$directory/\$filename	\$FileSize#	\$ImageWidth	\$ImageHeight	\$DocumentName#' -r $path`;
	close F;

	print "Created $OUTFILE\n";
}

sub buildTimeHash {
	my ($path) = @_;
	open F, "$path";
	my %timeHash;
	while(<F>) {
		my $withBaseName = aug_basename($_);
		my ($bname, $timestamp ) = split /\t/, $withBaseName;
		if (!$timeHash{$timestamp})  {
			$timeHash{$timestamp} = [];
		}
		push @{$timeHash{$timestamp}}, $withBaseName;
	}

	close F;
	return \%timeHash;
}

sub buildNameHash {
	my ($path) = @_;
	open F, "$path";
	my %nameHash;
	while(<F>) {
		my $withBaseName = aug_basename($_);
		my ($bname, $timestamp ) = split /\t/, $withBaseName;
		if (!$nameHash{$bname})  {
			$nameHash{$bname} = [];
		}
		push @{$nameHash{$bname}}, $withBaseName;
	}
	close F;
	return \%nameHash;
}









# add the basename to the metadata for the list
# Also manipulate basename to remove flickr file weirdness
sub aug_basename {
	my ($item) = @_;
	chomp; 
	my ($ts, $fname) = split /\t/;
	my $bname = $fname;
	$bname =~ s/^.+\///;
	$bname = lc($bname);
	if ($fname =~ /flickr/) {
		$bname =~ s/(\.\w+)$//;
		my $ext = $1;
		$bname =~ s/\_o$//;
		$bname =~ s/_\d+$//;
		$bname = $bname.$ext;
	}
	return "$bname\t$_";
}


sub mkdir_recursive {
    my $path = shift;
    mkdir_recursive(dirname($path)) if not -d dirname($path);
    mkdir $path or die "Could not make dir $path: $!" if not -d $path;
    return;
}

sub mkdir_and_copy {
    my ($from, $to) = @_;
    mkdir_recursive(dirname($to));
    system ('cp','-p',$from,$to);
    #copy($from, $to) or die "Couldn't copy: $!";
    return;
}

sub copyToTree {
	my ($copyTarget, $itemInfo) = @_;
	print "Copy target: $copyTarget\n";
	print "Item Info: $itemInfo\n";
	my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $itemInfo;
	$copyTarget =~ s~/$~~;
	$fname =~ s~^/~~;
	my $dest = "$copyTarget/$fname";
	print "Copy $fname   :  $dest\n";
	mkdir_and_copy($fname, $dest);
}
	

