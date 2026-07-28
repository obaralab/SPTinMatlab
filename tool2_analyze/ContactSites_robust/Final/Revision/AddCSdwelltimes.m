
function CS_v3=AddCSdwelltimes(CSstruct,DwellDir,ClassDir)

        % This is for adding dwell times calculated elsewhere to an
        % exisiting v2 CS structure. It is not assumed that all CS's will
        % have data associated, but it is assumed that if they are not all
        % accounted for, then the legacy indexes will be available for all
        % analyzed CSs.


        if nargin==1
            DwellDir=fullfile(pwd,"TempFolder/");
            ClassDir=fullfile(pwd,'TempClassFolder/');
        end

        % Find number of flagged and non-flagged contact sites
        NumCS=size(CSstruct,2);
        FlagInd=find(cell2mat({CSstruct.MitoFlag}));
        NumFlag=size(FlagInd,2);

        % Find the output files from DwellTimesManualv2.m and
        % EntryExitManualClassifierv2
        Files=dir(fullfile(ClassDir,'CS_*.mat'));
        NumCSfiles=size(Files,1);
        if NumCSfiles~=size(dir(fullfile(ClassDir,'CS_*.mat')),1)
            error('The Dwell Time data has not all been classified. Complete before proceeding.');
        end

        % Add empty fields to hold the data
        CSstruct(1).trackBinding=[];
        CSstruct(1).NumEntry=[];
        CSstruct(1).NumExit=[];
        CSstruct(1).DwellTimes=[];

        if NumCS==NumCSfiles
            % All the data is analyzed, use everything.
            disp('Dwell times measured for all contact sites.')
            ProcInd=1:NumCS;

            % Generate the binding info structure as a backup
            BindingInfo=AssembleDwellTimesData(CSstruct,DwellDir);

        elseif NumFlag==NumCSfiles
            % There is dwell time data for all flagged CSs
            disp('Dwell times only avaialable for flagged contact sites. Using empty entries for others.')
            ProcInd=FlagInd;

            % Generate the binding info structure as a backup
            BindingInfo=AssembleDwellTimesData(CSstruct(ProcInd),DwellDir);
            
        elseif NumCSfiles==0
            %Dwell Times have not been measured for this condition, yet.
            disp('Cannot find dwell time data. Filling fields with emptry arrays for later writing.')
            ProcInd=[];
            BindingInfo=[];
        else
            error('The number of files in DwellDir does not correspond to the CSstruct entered. Check the data is right, if so you must align manually.')
        end
        
        % Load the classified data and extract the missing fields
        for i=1:size(ProcInd,2)
            load(fullfile(ClassDir,strcat('CS_',num2str(CSstruct(ProcInd(i)).CSindex),'.mat')),'A');
            CSstruct(ProcInd(i)).trackBinding=A.trackBinding;
            CSstruct(ProcInd(i)).NumEntry=A.NumEntry;
            CSstruct(ProcInd(i)).NumExit=A.NumExit;
            CSstruct(ProcInd(i)).DwellTimes=A.DwellTimes;

            %Add the right indexes to BindingInfo
            BindingInfo(i).CS_index=ProcInd(i);
        end

        CS_v3=CSstruct;
        CS_v3=orderfields(CS_v3, [1:6 16 26:28 7 10 8 15 9 11:14 17:19 22:24 20 21 29 25]);
        save('BindingInfo.mat','BindingInfo');



