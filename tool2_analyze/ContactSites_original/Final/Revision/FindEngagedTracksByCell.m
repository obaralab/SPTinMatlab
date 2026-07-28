
function [CSinteractionsByCell]=FindEngagedTracksByCell(TrackStruct,CSstruct)

    CSinteractionsByCell=struct('cellIndex',[],'NumCSs',[],'BindTraj',[],'NoBindTraj',[],'NoSeeTraj',[]);
        % BindTraj showed binding, NoBindTraj saw the CS and didn't bind,
        % NoSeeTraj did not see the CS.

    for i=1:size(TrackStruct,2)
        
        CSinteractionsByCell(i).cellIndex=TrackStruct(i).cellIndex;
        CSinteractionsByCell(i).NumCSs=size(TrackStruct(i).MitoCSindex,2);

        for j=1:CSinteractionsByCell(i).NumCSs
        
            CSinteractionsByCell(i).BindTraj=[CSinteractionsByCell(i).BindTraj ...
                CSstruct(TrackStruct(i).CSindexes(j)).tracks(find(CSstruct(TrackStruct(i).CSindexes(j)).trackBinding))];

            CSinteractionsByCell(i).NoBindTraj=[CSinteractionsByCell(i).NoBindTraj ...
                CSstruct(TrackStruct(i).CSindexes(j)).tracks(find(CSstruct(TrackStruct(i).CSindexes(j)).trackBinding==0))];

        end

        % Remove duplicates from trajectories that interacted with multiple
        %CSs

        % NOTE: Modifying this section could help to identify if molecules
        % show engement bias or not

        CSinteractionsByCell(i).BindTraj=unique(CSinteractionsByCell(i).BindTraj);
        CSinteractionsByCell(i).NoBindTraj=unique(CSinteractionsByCell(i).NoBindTraj);

        % Remove molecules that engaged other CSs from the NoBindTraj list

        CSinteractionsByCell(i).NoBindTraj=CSinteractionsByCell(i).NoBindTraj(~ismember(CSinteractionsByCell(i).NoBindTraj,CSinteractionsByCell(i).BindTraj));

        % Find the trajectories that never saw a CS

         CSinteractionsByCell(i).NoSeeTraj=find(~ismember(1:size(TrackStruct(i).lengths,1),[CSinteractionsByCell(i).BindTraj CSinteractionsByCell(i).NoBindTraj]));

    end

end