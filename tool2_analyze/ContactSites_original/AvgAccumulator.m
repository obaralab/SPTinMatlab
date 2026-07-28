
% AvgAccumulator

function [A,B,C]=AvgAccumulator(CStype)

for i=1:size(CStype,2)
    n(i)=CStype(i).numLoc;
end

MaxNum=max(n,[],'all');
A=NaN(MaxNum,size(CStype,2));
B=NaN(MaxNum,size(CStype,2));
C=NaN(MaxNum,size(CStype,2));

for i=1:size(CStype,2)
    A(1:n(i),i)=CStype(i).X_c;
    B(1:n(i),i)=CStype(i).Y_c;
    C(1:n(i),i)=CStype(i).D;
end


end