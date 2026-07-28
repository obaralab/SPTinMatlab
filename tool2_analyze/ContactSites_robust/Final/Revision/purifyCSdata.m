
function CSdataOut=purifyCSdata(CSdataIn)

%This removes CS structures that failed a flag, so they don't screw up
%later programs
counter=0;

for i=1:size(CSdataIn,2)

    if CSdataIn(i).MitoFlag
        counter=counter+1;
        CSdataOut(counter)=CSdataIn(i);
    end
end

if ~exist("CSdataOut")
    CSdataOut=[];
end

end