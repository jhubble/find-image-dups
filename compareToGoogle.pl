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
GetOptions (\%options,qw(--compare --make-list --takeout-dir=s --photos-dir=s --takeout-list=s --photos-list=s -h --help --include-all --copy-photos-to-dir=s --copy-takeout-to-dir=s));

if ($options{"h"} || $options{'help'}) {
	show_help();
}

sub show_help {
	print <<EOF1;
compareToGoogle.pl
Find duplicate images and organize library
Jeremy Hubble April 28, 2024

--compare		Compare files ; If  dir is specified, filelist will be created
--make-list		Create filelist (via exiftool)
--photos-dir dir	fingerprint file output using jdupes
--takeout-dir dir	dup file
--photos-list file	directory to do searches (default $options{'photos-list'})
--takeout-list file	directory where data files (filelists, etc.) are located (default $options{'takeout-list'})
--include-all		default is faluse. Include all files in comparison if set. Otherwise, only include valid google photos extensions
		photo extensions: $valid_photo_extensions
		video extensions: $valid_video_extensions
--copy-photos-to-dir dir	Copy photos not in takeout to directory tree
--copy-takeout-to-dir dir	Copy takeout files not in photos to diectory tree
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

exit();
}

if ($options{"make-list"} || $options{compare}) {
	if ($options{'takeout-dir'}) {
		&create_exif_list($options{'takeout-dir'}, $options{'takeout-list'});
	}
	if ($options{'photos-dir'}) {
		&create_exif_list($options{'photos-dir'}, $options{'photos-list'});
	}
}
else {
	show_help();
}

if ($options{"compare"}) {
	## start with a simple name compare
	my $takeoutRef = buildNameHash($options{'takeout-list'});
	my %takeoutNameIndex = %{$takeoutRef};
	my $photoRef = buildNameHash($options{'photos-list'});
	my %photoNameIndex = %{$photoRef};

	print "TAKEOUT LIST: ",$options{'takeout-list'},"\n";
	print "PHOTO LIST  : ",$options{'photos-list'},"\n";
	if ($options{'copy-photos-to-dir'}) {
		print "COPYING missing photos to: $options{'copy-photos-to-dir'}\n";
	}
	if ($options{'copy-takeout-to-dir'}) {
		print "COPYING missing photos to: $options{'copy-takeout-to-dir'}\n";
	}

	my ($not_in_photos, $different_in_photos, $same_in_photos) = compareNameLists(\%takeoutNameIndex, \%photoNameIndex, $options{'copy-takeout-to-dir'});
	my ($not_in_takeout) = compareNameLists(\%photoNameIndex, \%takeoutNameIndex, $options{'copy-photos-to-dir'});

	my $not_photos = scalar @$not_in_photos;
	my $not_takeout = scalar @$not_in_takeout;
	my $same_count = scalar @$same_in_photos;
	my $diff_count = scalar @$different_in_photos;

	print "\nNot in photos:\n",join("\n",map {"$takeoutNameIndex{$_}[0]"} @$not_in_photos),"\n";
	print "\n====================================================================\n";
	print "\nNot in takeout:\n",join("\n",map {$photoNameIndex{$_}[0]} @$not_in_takeout),"\n";
	print <<EOF1;
	Not in photos :             $not_photos
	Not in takeout:             $not_takeout
	Same name, different count: $diff_count
	Same name, same count     : $same_count
EOF1
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
	my @not_in_second;
	my @same_in_second;
	my @different_in_second;
	foreach my $index (keys %list1) {
		## only process non-json files unless otherwise specified
		if (!$options{'include-all'} || $index =~ /$extensionsRegex/i) {
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
				if ($copy_target) {
					copyToTree($copy_target, $list1{$index}[0]);
				}
			}
		}
	}
	return (\@not_in_second, \@different_in_second, \@same_in_second);
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
		if (!timeHash{$timestamp})  {
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


## some remnants from another script for reference. May use them eventually
sub size_sort
{
	my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $a;
	my ($bname2, $ts2, $fname2, $size2, $width2, $height2) = split /\t/, $b;
	return ($bname <=> $bname2 
		or
	$fname cmp $fname2);
}

sub sort_by_size
{
	my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $a;
	my ($bname2, $ts2, $fname2, $size2, $width2, $height2) = split /\t/, $b;
	return $size <=> $size2;
}
sub name_sort
{
	my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $a;
	my ($bname2, $ts2, $fname2, $size2, $width2, $height2) = split /\t/, $b;
	# a < b -1   a == b 0   a>b 1
	my $rdir = $fname;
	my $rdir2 = $fname2;
	$rdir =~ s/^\.\///;
	$rdir2 =~ s/^\.\///;
	$rdir =~ s/\/.+$//;
	$rdir2 =~ s/\/.+$//;
	my $base = $rdir2 =~ /^\d|^moreYears/ - $rdir =~/^\d|^moreYears/;
	return ($base 
		or
	$fname <=> $fname2 
		or
	$width cmp $width2);
}

# to see sorted by amount
#cat allFiles.txt|sort -t$'\t' -k3 -n |cut -f2
sub list_by_extension {
	my ($listPath) = @_;
	print "======== LIST BY EXTENSION ======\n";
	open F, $listPath;
	my %HOA;
	while(<F>) {
		chomp; 
		my ($ts, $fname, $size, $width, $height) = split /\t/;
		my $ext = $fname;
		$ext =~ s/^.+\.//;
		if (!$HOA{$ext})  {
			$HOA{$ext} = [];
		}
		push @{$HOA{$ext}}, $_;
	}
	close F;
	for my $ext (sort keys %HOA) {
		my @arr = @{$HOA{$ext}};
		my $totalSize =0;
		foreach (@arr) {
			my ($ts, $fname, $size, $width, $height) = split /\t/;
			$totalSize += $size;
		}

		print "$ext\t",($#arr+1),"\t: $totalSize\n";
		if ($#arr < 10) {
			print @arr, "\n";
		}
	}

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
	

