
for i=1:4
    
    filename=char(Tracks(i).file);
    filebase=filename(1:end-7);
    
    imS=ChrisPrograms.loadtiff(fullfile(pwd,'MaxInt',strcat(filebase,'_3_maxS2N_max_RGB.tif')));
    
   TracksOverRawImageOptovarIn(Tracks,i,imS)
   
end