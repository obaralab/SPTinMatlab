
function TracksUpdated=AssignCSindexByCellv2(TrackStruct,CSstruct)


CSindexes=CSindiciesByFlag(CSstruct);

TracksUpdated=TrackStruct;

for j=1:size(TrackStruct,2)

    TracksUpdated(j).cellIndex=j;
    TracksUpdated(j).MCSindex=CSindexes(j).MCSindex;
    TracksUpdated(j).OCSindex=CSindexes(j).OCSindex;
    
end

if isfield(Tracks,'CSindexes') %Check if the structure has legacy indexes that may be needed for accessing old data
    TracksUpdated=orderfields(TracksUpdated,[1 24 2:17 18:23 25 26]);
else
    TracksUpdated=orderfields(TracksUpdated,[1 23 2:17 18:22 24 25]);
end