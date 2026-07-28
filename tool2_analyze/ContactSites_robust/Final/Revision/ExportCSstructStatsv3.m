
function  [OutTable,Din,Dout,Area]=ExportCSstructStatsv3(CSstruct)

% Original Stats that are still good from v1
    CS_Number=NaN(size(CSstruct,2),1);
    CS_Legacy=NaN(size(CSstruct,2),1);
    cellIndex=NaN(size(CSstruct,2),1);
    csID=NaN(size(CSstruct,2),1);
    numTracks=NaN(size(CSstruct,2),1);
    numNPBtracks=NaN(size(CSstruct,2),1);
    numSegIDs=NaN(size(CSstruct,2),1);
    MajorAx=NaN(size(CSstruct,2),1);
    MinorAx=NaN(size(CSstruct,2),1);
    Angle=NaN(size(CSstruct,2),1);
    numChPts=NaN(size(CSstruct,2),1);
    MitoFlag=NaN(size(CSstruct,2),1);

% Corrected Stats in v2
    Din=NaN(size(CSstruct,2),1);
    inNum=NaN(size(CSstruct,2),1);
    Dout=NaN(size(CSstruct,2),1);
    outNum=NaN(size(CSstruct,2),1);
    Area=NaN(size(CSstruct,2),1);

% Added Stats in v3
    numBoundTracks=NaN(size(CSstruct,2),1);
    numBindEvents=NaN(size(CSstruct,2),1);
    numEntry=NaN(size(CSstruct,2),1);
    numExit=NaN(size(CSstruct,2),1);
    numRebind=NaN(size(CSstruct,2),1);
  

    for i=1:size(CSstruct,2)
        % v1 info
        CS_Number(i)=CSstruct(i).CS_index; % This is ID within the dataset
        if ~isempty(CSstruct(i).CSindex)
            CS_Legacy(i)=CSstruct(i).CSindex;
        end
        cellIndex(i)=CSstruct(i).cellIndex;
        csID(i)=CSstruct(i).csID; % This is ID within the cell
        numTracks(i)=size(CSstruct(i).tracks,2);
        numNPBtracks(i)=nnz(isfinite(CSstruct(i).tracksCCids));
        numSegIDs(i)=size(unique(nonzeros(CSstruct(i).segIDs(isfinite(CSstruct(i).segIDs)))),1);
        MajorAx(i)=CSstruct(i).EllipseFit.MajorAxisLength;
        MinorAx(i)=CSstruct(i).EllipseFit.MinorAxisLength;
        Angle(i)=CSstruct(i).EllipseFit.Orientation;
        numChPts(i)=sum(CSstruct(i).ChPts(CSstruct(i).CSLocIDs),'all','omitnan');

        % v2 updates
        Din(i)=median(CSstruct(i).refDeff,"all",'omitnan');
        inNum(i)=size(CSstruct(i).refLocIDs,1);
        Dout(i)=median(CSstruct(i).neighborDeff,"all",'omitnan');
        outNum(i)=size(CSstruct(i).neighborIDs,1);
        Area(i)=polyarea(CSstruct(i).refboundary(:,1),CSstruct(i).refboundary(:,2));
        MitoFlag(i)=CSstruct(i).MitoFlag;

        % v3 updates              
        numBoundTracks(i)=nnz(CSstruct(i).trackBinding);
        numBindEvents(i)=sum(CSstruct(i).trackBinding,'all');
        numEntry(i)=sum(CSstruct(i).NumEntry,"all",'omitnan');
        numExit(i)=sum(CSstruct(i).NumExit,"all",'omitnan');
        numRebind(i)=nnz(CSstruct(i).trackBinding>1);
        
    end

    OutTable=table(CS_Number,CS_Legacy,cellIndex,csID,numTracks,numBoundTracks,numNPBtracks,numSegIDs,...
        numChPts,numBindEvents,numEntry,numExit,numRebind,MajorAx,MinorAx,Angle,Area, Din,inNum,Dout,outNum, MitoFlag);

    writetable(OutTable,'CS_details_v2.xlsx');



end