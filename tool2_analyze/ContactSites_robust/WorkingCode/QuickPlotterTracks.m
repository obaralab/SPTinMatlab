
for i=1:18
    
    filename=char(Tracks(i).file);
    filebase=cellBase(filename);
    
    imS=ChrisPrograms.loadtiff(fullfile(pwd,'MaxInt',strcat(filebase,'_3_MaxInt_RGB.tif')));
    
   TracksOverRawImage(Tracks,i,imS)
   
end