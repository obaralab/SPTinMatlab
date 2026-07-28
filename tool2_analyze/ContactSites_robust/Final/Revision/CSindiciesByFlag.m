
function [CSindices]=CSindiciesByFlag(CSstruct)

    CellDistribution=cell2mat({CSstruct.cellIndex});
    MitoFlags=cell2mat({CSstruct.MitoFlag});
    NumCells=max(CellDistribution,[],"all");
    CSindices=struct('MCSindex',[],'OCSindex',[]);
    for i=1:NumCells
        CSindices(i).MCSindex=find((CellDistribution==i).*MitoFlags);
        CSindices(i).OCSindex=find((CellDistribution==i).*(~MitoFlags));
    end
end