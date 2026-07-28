
function [A,B,C]=ExportTrackLengthsByCondition(TrajClassLengths)

% Run this on the output structure from TrajLengthsByCell

A=[];
B=[];
C=[];

for i=1:size(TrajClassLengths,2)
  
    A=[A; TrajClassLengths(i).cellIndex*ones(size(TrajClassLengths(i).BindTrajLengths)), TrajClassLengths(i).BindTrajLengths];
    B=[B; TrajClassLengths(i).cellIndex*ones(size(TrajClassLengths(i).NoBindTrajLengths)), TrajClassLengths(i).NoBindTrajLengths];
    C=[C; TrajClassLengths(i).cellIndex*ones(size(TrajClassLengths(i).NoSeeLengths)), TrajClassLengths(i).NoSeeLengths];

end

