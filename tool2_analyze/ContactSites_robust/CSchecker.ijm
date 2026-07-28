
dir1 = getDirectory("Choose Source Directory Left: ");
input = dir1;

dir2 = getDirectory("Choose Source Directory Right: ");
input2=dir2;

dir3 = getDirectory("Choose CS roi location: ");

list = getFileList(input);
list2 = getFileList(input2);


for (i = 0; i < list.length; i++) {
	filename1=list[i];
	filename2=list2[i];

	open(input+filename1);	
	run("Set... ", "zoom=75");
	run("Set Scale...", "distance=0 known=0 unit=pixel");
	L=lengthOf(filename1);
	filebase=substring(filename1,0,L-14);

	open(input2+filename2);
	run("Size...", "width=1200 height=1200 depth=1 constrain average interpolation=None");
	run("Set... ", "zoom=75");
	run("Tile");

	roiManager("reset");
	roiManager("Open", dir3+filebase+"rois.zip");
	roiManager("Show All");
	waitForUser;

	run("Close All");
}

