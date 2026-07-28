
% Cell Accumulator

Files=dir(fullfile(pwd,'*_Tracks.mat'));

files={Files.name}';

for i=1:size(files,1)
    
   load(char(files{i}));
   Tracks(i)=CellTracks; 
   
end
