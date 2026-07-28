
function [BindingTable]=ExtractBindingInfo(CSstruct)

[NumContacts]=size(CSstruct,2);
Counter=0;

for i=1:NumContacts
    BindingTracks=find(CSstruct(i).trackBinding);
    NumBindingTracks=size(BindingTracks,2);
    for j=1:NumBindingTracks
        NumInteractions=CSstruct(i).trackBinding(BindingTracks(j));
        for k=1:NumInteractions
            Counter=Counter+1;
            CSindex(Counter)=CSstruct(i).CSindex;
            trackID(Counter)=CSstruct(i).tracks(BindingTracks(j));
            IntNum(Counter)=k;
            Entry(Counter)=CSstruct(i).DwellTimes(BindingTracks(j)).EntryBool(k);
            Exit(Counter)=CSstruct(i).DwellTimes(BindingTracks(j)).ExitBool(k);
            DwellTime(Counter)=CSstruct(i).DwellTimes(BindingTracks(j)).DwellTimes(k,1);
        end

    end

end

CSsize=NaN(Counter,2);
CSarea=NaN(Counter,1);
CS_Deff=NaN(Counter,1);
CS_Neighbor=NaN(Counter,1);
CS_MitoFlag=NaN(Counter,1);

for l=1:Counter
    CSsize(l,1)=CSstruct(CSindex(l)).EllipseFit.MajorAxisLength;
    CSsize(l,2)=CSstruct(CSindex(l)).EllipseFit.MinorAxisLength;
    CSarea(l)=polyarea(CSstruct(CSindex(l)).refboundary(:,1),CSstruct(CSindex(l)).refboundary(:,2));
    CS_Deff(l)=median(CSstruct(CSindex(l)).refDeff,"all","omitnan");
    CS_Neighbor(l)=median(CSstruct(CSindex(l)).neighborDeff,"all","omitnan");
    CS_MitoFlag(l)=CSstruct(CSindex(l)).MitoFlag;
end

BindingTable=table(CSindex', trackID', IntNum', Entry', Exit', DwellTime', CSsize, CSarea, CS_Deff, CS_Neighbor, CS_MitoFlag);
ColumnNames={'CS Index', 'Track ID', 'Interaction #', 'Entry?', 'Exit?', 'DwellTime', 'CS size'};
BindingTable=renamevars(BindingTable,{'Var1', 'Var2', 'Var3', 'Var4', 'Var5', 'Var6', 'CSsize'},ColumnNames);


end

