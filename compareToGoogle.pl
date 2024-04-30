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
use File::Copy;
use File::Basename;
use Data::Dumper;

my %options=();

$options{'takeout-list'} = 'takeoutlist.txt';
$options{'photos-list'} = 'photoslist.txt';
GetOptions (\%options,qw(--compare --make-list --takeout-dir=s --photos-dir=s --takeout-list=s --photos-list=s -h --help));

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
--photos-list file	directory to do searches (default ./)
--takeout-list file	directory where data files (filelists, etc.) are located (default ./)
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
	print "PHOTO LIST  : ",$options{'photo-list'},"\n";

	my ($not_in_photos, $different_in_photos, $same_in_photos) = compareLists(\%takeoutNameIndex, \%photoNameIndex);
	my ($not_in_takeout) = compareLists(\%photoNameIndex, \%takeoutNameIndex);

	my $not_photos = scalar @$not_in_photos;
	my $not_takeout = scalar @$not_in_takeout;
	my $same_count = scalar @$same_in_photos;
	my $diff_count = scalar @$different_in_photos;

	print "\nNot in photos:\n",join("\n",@$not_in_photos),"\n";
	print "\nNot in takeout:\n",join("\n",@$not_in_takeout),"\n";
	print <<EOF1;
	Not in photos :             $not_photos
	Not in takeout:             $not_takeout
	Same name, different count: $diff_count
	Same name, same count     : $same_count
EOF1
}

sub compareLists  {
	my @lists = @_;
	my %list1 = %{$lists[0]};
	my %list2 = %{$lists[1]};
	my @not_in_second;
	my @same_in_second;
	my @different_in_second;
	foreach my $index (keys %list1) {
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


