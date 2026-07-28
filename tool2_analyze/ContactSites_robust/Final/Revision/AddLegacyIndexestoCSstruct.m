
function CS_updated=AddLegacyIndexestoCSstruct(CSstruct)

    LegacyIndKey=find(cell2mat({CSstruct.MitoFlag}));

    
    CSstruct(1).CSindex=[];
    CSstruct(1).CS_index=[];

    % Explicitly assign the v3 index so you can't get them confused later
    for i=1:size(CSstruct,2)
        CSstruct(i).CS_index=i;
    end

    % Assigne Legacy Indexes when they exist
    for i=1:size(LegacyIndKey,2)
        CSstruct(LegacyIndKey(i)).CSindex=i;
    end

    % Move these new fields to the top of the list for convenience
    CS_updated=CSstruct;
    CS_updated=orderfields(CS_updated,[length(fieldnames(CSstruct)), length(fieldnames(CSstruct))-1, 1:length(fieldnames(CSstruct))-2]);

end