
function BindingInfo=AssembleDwellTimesData(CSstruct,TempFolder)

% TempFolder is where the backup outputs from DwellTimeManual are stored

if nargin==1
    TempFolder=pwd;
end

cd(TempFolder)

BindingInfo=struct('csID',[],'trackBinding',[],'DwellTimesData',[]);

for i=1:size(CSstruct,2)
    load(['CS_' num2str(CSstruct(i).CSindex), '.mat']);
    BindingInfo(i).csID=i;
    BindingInfo(i).trackBinding=trackBinding;
    BindingInfo(i).DwellTimesData=trackDwellTimes;
end

cd ..