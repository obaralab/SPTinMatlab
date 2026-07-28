
function  [OutTable,Din,Dout,Area]=ExportCSstatsv2struct(CSstruct)

    Din=NaN(size(CSstruct,2),1);
    Dout=NaN(size(CSstruct,2),1);
    Area=NaN(size(CSstruct,2),1);
    MitoFlag=NaN(size(CSstruct,2),1);

    for i=1:size(CSstruct,2)
        Din(i)=median(CSstruct(i).refDeff,"all",'omitnan');
        Dout(i)=median(CSstruct(i).neighborDeff,"all",'omitnan');
        Area(i)=polyarea(CSstruct(i).refboundary(:,1),CSstruct(i).refboundary(:,2));
        MitoFlag(i)=CSstruct(i).MitoFlag;
        
    end

    CSlabels=1:size(CSstruct,2);
    OutTable=table(CSlabels', Din, Dout, Area,MitoFlag);

    writetable(OutTable,'CS_details_v2.xlsx');



end