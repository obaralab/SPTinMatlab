
% Part 1

%Load Tracks

filename=dir(fullfile(pwd,'*_vector.mat'));
load(char(filename),'Tracks');

mkdir Density1D
cd Density1D

for i=1:size(Tracks,1)
    
    Tracks(i).MSDdata=[];
    LocDensityFigIntUse(Tracks,i,30);
    
end

cd ..
save

mkdir Densities
cd Densities

DensityVisualization(Tracks,30,true);

cd ..

mkdir Overlay
cd Overlay

TrackOverlayMaker(Tracks)

cd ..