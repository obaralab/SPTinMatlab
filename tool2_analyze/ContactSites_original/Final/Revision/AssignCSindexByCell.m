
function TracksUpdated=AssignCSindexByCell(TrackStruct,CSstruct)


CSindexes=cell(size(TrackStruct,2),1);

for i=1:size(CSstruct,2)

    CSindexes{CSstruct(i).cellIndex}=[ CSindexes{CSstruct(i).cellIndex} i];

end

TracksUpdated=TrackStruct;

for j=1:size(TrackStruct,2)

    TracksUpdated(j).CSindexes=CSindexes{j};
    TracksUpdated(j).cellIndex=j;

end


TracksUpdated=orderfields(TracksUpdated,[1 24 2:17 23 18:22]);