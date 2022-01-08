#!/usr/bin/perl
use strict;
use Cwd qw(getcwd);
use Getopt::Std;

my %options=();

$options{"w"} = "./";
$options{"d"} = "./";

getopts("l:m:f:p:w:d:vh123s4c56", \%options);


if ($options{"h"}) {
	show_help();
}

sub show_help {
	print <<EOF1;
findDups.pl
Find duplicate images and organize library
Jeremy Hubble Jan 8, 2022

-l filelist		Use filelist of all files for finding duplicates 
-m filelist		Create filelist (via exiftool)
-f fingerprintfile	fingerprint file output using jdupes
-p dupefile		dup file
-w workingdir		directory to do searches (default ./)
-d datadir		directory where data files (filelists, etc.) are located (default ./)
-v			print verbose information
-h			print this help
-1			delete by time - delete all files with the same time exiftag that
			also have same filesize and width
			and are in tvComputer or flickr directory
-2			delete files with width <320 and filesize <20000
-3			delete flickr same files
			files must have flickr in name. Matches files with same basename
			(stripping off _o or _#### from the end)
			and have same filesize and width
-s			List stats of counts of files by extension
-4 			Delete files with same fingerprints. The largest file will be maintained
			Requires fingerprint file
-c			creates a filelist prefixed by new_ that removes files that
			have been deleted from original filelist (does not alter original)
-5			Validate directories
			Move files to the date indicated in thier DateTimeCreated exiff tag
			Also writes the original filename to the exif tag
-6			Process Dup List - print a list of all matches from dup list

Examples:
findDups.pl -m filelist.txt		# create the exiflif of files in current directory
findDips.pl -l filelist.txt -2		# delete small files
EOF1

exit();
}

if ($options{"m"}) {
	create_exif_list();
	exit;
}
if (!$options{"l"}) {
	show_help();
}

# first clear out exact dupes - https://github.com/jbruchon/jdupes
# jdupes -r . 
# will list exact dupes
#
# Use some version of findimagedupes
# https://github.com/pts/pyfindimagedupes
# http://manpages.ubuntu.com/manpages/bionic/man1/findimagedupes.1p.html
#
my $FILE = $options{l};
my $FPFILE = $options{f};
my $DUPFILE = $options{p};
my $VERBOSE = $options{v};
#my $WORKING_DIR = "/mnt/c/Users/bh/Pictures";
#my $DATA_DIR = "/mnt/c/Users/bh/phototxt";
my $WORKING_DIR = $options{w};
my $DATA_DIR = $options{d};


sub create_exif_list() {
	print "==== Creating exiftool list =====";
	if ($options{l}) {
		print "Cannot specify existing list while creating new one\n";
		show_help();
	}
	my $OUTFILE = "$DATA_DIR".$options{m};
	open F, ">$OUTFILE";
	chdir($WORKING_DIR);
	print F `exiftool -fast -fast2 -f -p '\$DateTimeOriginal	\$directory/\$filename	\$FileSize#	\$ImageWidth	\$ImageHeight	\$DocumentName' -r .`;
	close F;

	print "Created $OUTFILE\n";
	exit();
}


sub delete_filterByTime {
	print "===== DELETE BY TIME ======\n";
	my $hoa = buildTimeHash();
	deleteByHash($hoa);
}

sub buildTimeHash {
	open F, "$DATA_DIR/$FILE";
	my %HOA;
	while(<F>) {
		my $withBaseName = aug_basename($_);
		my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $withBaseName;
		if (!$HOA{$ts})  {
			$HOA{$ts} = [];
		}
		push @{$HOA{$ts}}, $withBaseName;
	}

	close F;
	return \%HOA;
}
sub deleteByHash {
	my ($h) = @_;
	my %HOA = %{$h};
	my $count = 0;
	my $totalSize = 0;

	for my $hashkey (sort keys %HOA) {
		#print "HASHKEY: $hashkey\n";
		my @arr = reverse sort name_sort @{$HOA{$hashkey}};
		if ($#arr > 1) {
			if ($VERBOSE) {
				print "\n$hashkey ";
				print $#arr,":";
				print (map { "\n".$_ } @arr);
				print "\n";
			}
			for (my $cmp =0; $cmp<$#arr; $cmp++) {
				my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $arr[$cmp];
				for (my $ind =$cmp+1; $ind<=$#arr; $ind++) {
					my ($bname2,$ts2, $fname2, $size2, $width2, $height2) = split /\t/, $arr[$ind];

					if ($size == $size2 && $width == $width2 && ($fname2 =~ /tvComputer/ || $fname2 =~ /flickr/) ) {
						my $l = unlink $fname2 ;
						print "$l $! -> rm $fname2 #: $fname, $ts=$ts2, $size=$size2, $width=$width2, $height=$height2\n";
						$count++;
						$totalSize += $size2;
					}
				}
			}

		}
	}
	print "*** $count deleted\n";
	print "*** $totalSize size\n";
}

sub fpHashDelete {
	my ($h, $fpref) = @_;
	my %HOA = %{$h};
	my %fps;
        if ($fpref != undef) {
       	   %fps = %{$fpref};
	}
	my $count = 0;
	my $totalSize = 0;

	for my $hashkey (sort keys %HOA) {
		my @arr = reverse sort name_sort @{$HOA{$hashkey}};
		if ($#arr >= 1) {
			my %fpgroups;
			if ($VERBOSE) {
				print "\nHASHKEY: $hashkey ";
				print "cout:",$#arr,":";
				print (map { "\n".$_ } @arr);
				print "\n";
			}
			for (my $cmp =0; $cmp<=$#arr; $cmp++) {
				my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $arr[$cmp];
				my $fp = $fps{$fname};
				if ($VERBOSE) {
					print "FINGER: $fp->$fname\n";
				}
				if ($fp) {
					if (!$fpgroups{$fp}) {
						$fpgroups{$fp} = [];
					}
					push @{$fpgroups{$fp}}, $arr[$cmp];
				}
			}
			for my $fpkey (keys %fpgroups) {
				my @fpgroupmembers = @{${fpgroups{$fpkey}}};
				if ($VERBOSE) {
					print "FINGERPRINT: $fpkey ,",$#fpgroupmembers,"\n";
				}
				if ($#fpgroupmembers > 0) {
					my @sorted = reverse sort sort_by_size @fpgroupmembers;
					for (my $i=1;$i<=$#sorted;$i++) {
						my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $sorted[$i];
						my $l = unlink $fname ;
						print "$l $! -> rm $fname #: $fpkey, $ts, $size, $width, $height\n";
						$count++;
						$totalSize += $size;
					}
				}
			}

		}
	}
	print "*** $count deleted\n";
	print "*** $totalSize size\n";
}
sub sameHashDifferentDate {
	print "== delete same fingerprint ==\n";
	my ($h, $fpref) = @_;
	my %HOA = %{$h};
	my %fps;


	my %filesByFp;
	my %filesByName;

        if ($fpref != undef) {
       	   %fps = %{$fpref};
	}
	my $count = 0;
	my $totalSize = 0;

	foreach my $file (keys %fps) {
		if (-f $file) {
			my $fingerprint = $fps{$file};
			if (!$filesByFp{$fingerprint}) {
				$filesByFp{$fingerprint} = [];
			}
			push @{$filesByFp{$fingerprint}}, $file;
		}
	}
	foreach my $ts (keys %HOA) {
		my @items = @{$HOA{$ts}};
		foreach my $item (@items) {
			my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $item;
			if (-f $fname) {
				$filesByName{$fname} = $item;
			}
		}
	}



	for my $hashkey (sort keys %filesByFp) {
		my @unmapped = @{$filesByFp{$hashkey}};
		my @arr = reverse sort size_sort map { $filesByName{$_} || () } @{$filesByFp{$hashkey}};
		if ($#arr >= 1) {
			print "Same fingerprints ($hashkey) (",$#arr+1,")\n";
			my ($bname0, $ts0, $fname0, $size0, $width0, $height0) = split / *\t/, $arr[0];
			for (my $cmp =0; $cmp<=$#arr; $cmp++) {
				my ($bname, $ts, $fname, $size, $width, $height) = split / *\t/, $arr[$cmp];
				if ($cmp >=1) {
					$count ++;
					$totalSize += $size;
					print ">(del?)>",$arr[$cmp],"\n";
					if (! -f $fname) {
						print "??HUH? >>$fname<<\n";
					}
					if ($ts eq '-') {
						if (!-f $fname) {
							print "----$fname does not exist\n";
						}
						my $l = unlink($fname);
						print "$l $! -> rm ($fname) \n";
					}
					elsif ($ts0 ne '-') {
						if (-f $fname0) {
							if (!-f $fname) {
								print "----$fname does not exist\n";
							}
							my $l = unlink($fname);
							print "$l $! -> rm ($fname) \n";
						}
					}
					else {
						print "not deleting: ($ts)\n";
					}
				}
				else {
					print "*(save)*",$arr[$cmp]," \n";
					if (!-f $fname) {
						print ">>>Uh, we have a problem, $fname does not exist\n";
						last;
					}
				}
			}
			print "\n";
		}
	}
	print "*** $count deleted\n";
	print "*** $totalSize size\n";
}
sub aug_basename {
	my ($item) = @_;
	chomp; 
	my ($ts, $fname, $size, $width, $height) = split /\t/;
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

sub delete_flickrSameName {
	print "===== FLICKR SAME NAME ======\n";
	open F, "$DATA_DIR/$FILE";
	my %HOA;
	while(<F>) {
		my $withBaseName = aug_basename($_);
		my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $withBaseName;
		if (!$HOA{$bname})  {
			$HOA{$bname} = [];
		}
		push @{$HOA{$bname}}, $withBaseName;
	}

	close F;

	deleteByHash(\%HOA);
}

sub size_sort
{
	my ($bname,$ts, $fname, $size, $width, $height) = split /\t/, $a;
	my ($bname2, $ts2, $fname2, $size2, $width2, $height2) = split /\t/, $b;
	return $bname <=> $bname2 
		or
	$fname cmp $fname2;
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
	return $base 
		or
	$fname <=> $fname2 
		or
	$width cmp $width2;
}

# to see sorted by amount
#cat allFiles.txt|sort -t$'\t' -k3 -n |cut -f2
sub list_by_extension {
	print "======== LIST BY EXTENSION ======\n";
	open F, "$DATA_DIR/$FILE";
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

sub delete_small_width {
	print "======  DELETE SMALL SIZE AND WIDTH ======\n";
	open F, "$DATA_DIR/$FILE";
	my $count=0;
	my %HOA;
	while(<F>) {
		chomp; 
		my ($ts, $fname, $size, $width, $height) = split /\t/;
		if (!$HOA{$width})  {
			$HOA{$width} = [];
		}
		push @{$HOA{$width}}, $_;
	}
	close F;
	for my $width (sort {$a <=> $b} keys %HOA) {
		my @arr = @{$HOA{$width}};
		if ($width < 320) {
			print "$width\t",($#arr+1),"\n";
			foreach my $f (@arr) {
				my ($ts, $fname, $size, $width, $height) = split (/\t/,$f);
				if ($size <20000) {
					$count++;
					unlink($fname);
					print "$size => ",$f,"\n";
				}
				else {
					print "TOO BIG:",$f,"\n";
				}
			}

		}
	}
	print "*** $count deleted\n";

}

sub clean_deleted {
	print "=========  CLEAN FILE LIST ==========\n";
	my $oldList = "$DATA_DIR/$FILE";
	my $newList = ">$DATA_DIR/new_$FILE";
	open F, $oldList;
	open NEW, $newList;
	if ($VERBOSE) {
		print "OLD: $oldList\nNEW: $newList\n";
		print getcwd, "\n";
	}
	my $count = 0;
	my $totalsize = 0;
	while(<F>) {
		chomp; 
		my ($ts, $fname, $size, $width, $height) = split /\t/;
		if (-e $fname) {
			if ($VERBOSE) {
				print "->PRESENT: $fname <<$_>>\n";
			}
			print NEW $_,"\n";
		}
		else {
			if ($VERBOSE) {
				print "_>Not Present:$ts,$fname,$size:<<$_>>\n";
			}
			$count++;
			$totalsize += $size;
		}
	}
	close F;
	close NEW;
	print "$count files removed\n";
	print "$totalsize space removed\n";
}
sub processFingerprints {
	print "=========  TIME FINGERPRINT==========\n";
	open F, "$DATA_DIR/$FPFILE";
	my %fpindex;
	print "... processing fingerprints\n";
	while (<F>) {
		chomp;
		my ($fp, $fname) = split (/\s+/,$_,2);
		if ($fp =~ /\/mnt\/c\/Users/) {
			if ($VERBOSE) {
				my @arr_count = (split /\/mnt/,$_);
				print "MATCH COUNT",($#arr_count+1),"\n";
			}
		}
		else {
			$fname =~ s~/mnt/c/Users/bh/Pictures~.~;
			#if (!$fpindex{$fp})  {
			#	$HOA{$fp} = [];
			#}
			#push @{$fpindex{$fp}}, $fname;
			$fpindex{$fname} = $fp;
		}
	}
	print "... getting time hash\n";
	my $hoa = buildTimeHash();
	print "... finding dups\n";
	fpHashDelete($hoa, \%fpindex);
	print "... fingerprints (any time) \n";
	sameHashDifferentDate($hoa, \%fpindex);
	# join these two indexes together
	
}

sub validateDirs {
	print "=== IDENTIFYING FILES IN WRONG YEAR DIRECTORY ====\n";
	my $hoa = buildTimeHash();
	my %HOA = %{$hoa};
	for my $hashkey (sort keys %HOA) {
		my @arr = reverse sort name_sort @{$HOA{$hashkey}};
		foreach my $f (@arr) {
			my ($bname, $ts, $fname, $size, $width, $height) = split /\t/, $f;
			$ts =~ m/(^\d\d\d\d)/;
			my $year = $1;
			$fname =~ m~./([^/]+)/~;
			my $fileYear = $1;
			if ($year ne $fileYear) {
				#if ($year ne $fileYear && $fileYear - $year > 1) {
				moveFiles($year,$fname);
				print "$year $fileYear ",$f,"\n";
			}

		}
	}
}

sub moveFiles {
	# move the files to directories
	print `exiftool '\$DocumentName	\$directory/\$filename' \$fname`
}

sub processDupList {
	use Data::Dumper;
	print "=== Getting list from dups ===\n";
	open F, "$DUPFILE";
	my @allMatches;
	while (<F>) {
		chomp;
		m~([^/]+/)~;
		my $filestart = $1;
		s~ $filestart~\t$filestart~;
		if ($VERBOSE) {
			print $_,"\n";
		}
		my @matches = split /\t/;
		push @allMatches, \@matches;
	}
	print Dumper(\@allMatches);
}

	
if (options{"1"}) {
	delete_filterByTime();
}
if (options{"2"}) {
	delete_small_width();
}
if (options{"3"}) {
	delete_flickrSameName();
}
if (options{"s"}) {
	list_by_extension();
}
if (options{"4"}) {
	processFingerprints();
}
if (options{"c"}) {
	clean_deleted();
}
# validate that files are in directory matching the exif data
if (options{"5"}) {
	validateDirs();
}
if (options{"6"}) {
	processDupList();
}
