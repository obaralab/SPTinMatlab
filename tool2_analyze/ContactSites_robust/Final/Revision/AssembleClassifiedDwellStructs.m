
function CS=AssembleClassifiedDwellStructs(TempClassFolder)

if nargin==0
    TempClassFolder=pwd;
end

Files=dir(fullfile(TempClassFolder,'*.mat'));

files={Files.name}';

for i=1:size(files,1)

    load(['CS_' num2str(i) '.mat'],'A');
    CS(i)=A;

end

if length(fieldnames(CS))==28
    CS=orderfields(CS, [1 2 3 24 4 14 25 27 28 5 8 6 13 7 9:12 15:22 26 23]);
end