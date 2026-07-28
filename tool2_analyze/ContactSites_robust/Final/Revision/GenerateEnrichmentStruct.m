
function [EnrichmentStruct]=GenerateEnrichmentStruct(TrackStruct,CSstruct)

    % Find the proportion of trajectories and localizations that are in a
    % particular class of CS vs others or freely diffusing

    % Get the CSindices for mining if not recorded in Tracks
    if ~isfield(TrackStruct,'MCSindex')
        [CSindices]=CSindiciesByFlag(CSstruct);
        for i=1:size(TrackStruct,2)
            TrackStruct(i).MCSindex=CSindices(i).MCSindex;
            TrackStruct(i).OCSindex=CSindices(i).OCSindex;
        end
    end

    EnrichmentStruct=struct('cellIndex',[]);

    % Collect all the tracks inside the CSs
        
    for i=1:size(TrackStruct,2)

        EnrichmentStruct(i).cellIndex=TrackStruct(i).cellIndex;
        EnrichmentStruct(i).NumMCSs=size(TrackStruct(i).MCSindex,2);
        EnrichmentStruct(i).NumOCSs=size(TrackStruct(i).OCSindex,2);

        EnrichmentStruct(i).MCSsteps=NaN(size(TrackStruct(i).MCSindex));
        EnrichmentStruct(i).OCSsteps=NaN(size(TrackStruct(i).OCSindex));
        EnrichmentStruct(i).TotalSteps=sum(isfinite(TrackStruct(i).matrix(:,:,2)),"all");
        EnrichmentStruct(i).MCStracks=[];
        EnrichmentStruct(i).OCStracks=[];
       
        for j=1:size(TrackStruct(i).MCSindex,2)
            
            EnrichmentStruct(i).MCSsteps(j)=size(CSstruct(TrackStruct(i).MCSindex(j)).refLocIDs,1);
            EnrichmentStruct(i).MCStracks=[EnrichmentStruct(i).MCStracks, CSstruct(TrackStruct(i).MCSindex(j)).tracks];

        end

        for j=1:size(TrackStruct(i).OCSindex,2)

            EnrichmentStruct(i).OCSsteps(j)=size(CSstruct(TrackStruct(i).OCSindex(j)).refLocIDs,1);
            EnrichmentStruct(i).OCStracks=[EnrichmentStruct(i).OCStracks, CSstruct(TrackStruct(i).OCSindex(j)).tracks];

        end

        %Remove duplicate tracks that saw multiple CSs
        EnrichmentStruct(i).MCStracks=unique(EnrichmentStruct(i).MCStracks);
        EnrichmentStruct(i).OCStracks=unique(EnrichmentStruct(i).OCStracks);

        EnrichmentStruct(i).FreeTracks=setdiff(1:size(TrackStruct(i).lengths,1),[EnrichmentStruct(i).MCStracks, EnrichmentStruct(i).OCStracks]);


    end


end