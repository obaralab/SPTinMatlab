
function OutputEnrichmentCoeffData(EnrichmentStruct)
    
    CellIndex=[];
    NumMCSsteps=[];
    NumOCSsteps=[];
    TotalSteps=[];
    MitoFlag=[];
    NumMCStracks=NaN(size(EnrichmentStruct,2),1);
    NumOCStracks=NaN(size(EnrichmentStruct,2),1);
    TotalTracks=NaN(size(EnrichmentStruct,2),1);
    NumMCSstepsCell=NaN(size(EnrichmentStruct,2),1);
    NumOCSstepsCell=NaN(size(EnrichmentStruct,2),1);
    TotalStepsPerCell=NaN(size(EnrichmentStruct,2),1);



    for i=1:size(EnrichmentStruct,2)

        % Collect data for table 1 (by steps)
        NumLines=EnrichmentStruct(i).NumMCSs+EnrichmentStruct(i).NumOCSs;
        CellIndex=[CellIndex; EnrichmentStruct(i).cellIndex*ones(NumLines,1)];
        NumMCSsteps=[NumMCSsteps; EnrichmentStruct(i).MCSsteps'; NaN(EnrichmentStruct(i).NumOCSs,1)];
        NumOCSsteps=[NumOCSsteps;  NaN(EnrichmentStruct(i).NumMCSs,1); EnrichmentStruct(i).OCSsteps'];
        TotalSteps=[TotalSteps; EnrichmentStruct(i).TotalSteps*ones(NumLines,1)];
        MitoFlag=[MitoFlag; ones(EnrichmentStruct(i).NumMCSs,1); zeros(EnrichmentStruct(i).NumOCSs,1)];

        % Collect data for table 2 (by tracks + steps by cell)
        NumMCStracks(i)=size(EnrichmentStruct(i).MCStracks,2);
        NumOCStracks(i)=size(EnrichmentStruct(i).OCStracks,2);
        TotalTracks(i)=size(EnrichmentStruct(i).FreeTracks,2);

        NumMCSstepsCell(i)=sum(EnrichmentStruct(i).MCSsteps,"all");
        NumOCSstepsCell(i)=sum(EnrichmentStruct(i).OCSsteps,"all");
        TotalStepsPerCell(i)=EnrichmentStruct(i).TotalSteps;

    end

    Cell=(1:size(EnrichmentStruct,2))';

    StepsTable=table(CellIndex,MitoFlag,NumMCSsteps,NumOCSsteps,TotalSteps);
    TracksTable=table(Cell,NumMCStracks, NumOCStracks,TotalTracks,NumMCSstepsCell,NumOCSstepsCell,TotalStepsPerCell);

    writetable(StepsTable,'EnrichmentCoefficients.xlsx','Sheet','StepEnrichmentByCS');
    writetable(TracksTable,'EnrichmentCoefficients.xlsx','Sheet','EnrichmentByCell');


end