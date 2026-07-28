
function TrajClassLengths=TrajLengthsByCell(TrackStruct,CSstruct)

% Pull out trajectory lengths by class (to look for bleaching biases by
% state)

    CSclasses=FindEngagedTracksByCell(TrackStruct,CSstruct);

    for i=1:size(CSclasses,2)

        CSclasses(i).BindTrajLengths=TrackStruct(CSclasses(i).cellIndex).lengths(CSclasses(i).BindTraj);
        CSclasses(i).NoBindTrajLengths=TrackStruct(CSclasses(i).cellIndex).lengths(CSclasses(i).NoBindTraj);
        CSclasses(i).NoSeeLengths=TrackStruct(CSclasses(i).cellIndex).lengths(CSclasses(i).NoSeeTraj);

    end

    TrajClassLengths=CSclasses;

end