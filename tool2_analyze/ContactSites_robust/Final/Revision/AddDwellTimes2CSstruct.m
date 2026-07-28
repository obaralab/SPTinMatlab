
function CSupdated=AddDwellTimes2CSstruct(CSstruct,BindingInfo)

% Binding info is the output of DwellTimesManual.m

    if size(BindingInfo,2)~=size(CSstruct,2)
        error('These two structured arrays do not match');
    end

    for i=1:size(CSstruct,2)
        if CSstruct(i).CSindex==BindingInfo(i).csID
            CSstruct(i).trackBinding=BindingInfo(i).trackBinding;
            CSstruct(i).DwellTimes=BindingInfo(i).DwellTimesData;
        else
            error('The csIDs are not matching up. Wrong order, perhaps?');
        end
    end
    CSupdated=CSstruct;
end