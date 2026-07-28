
%Part 2

% ContactSiteMapper

cd TrackData

CStabulator
CellAccumulator

cd ..
writetable(T,'CSstats.xlsx','WriteRowNames',true);
save('CSindexing.mat','CSinfo');

save('Tracks_final.mat','Tracks')

clear all
load('Tracks_final.mat')
load('CSindexing.mat')

for i=1:size(Tracks,2)
    
    Tracks(i).MitoCSindex=CSinfo(i).CSindex;
    
end

save('Tracks_final.mat','Tracks');
clear all
