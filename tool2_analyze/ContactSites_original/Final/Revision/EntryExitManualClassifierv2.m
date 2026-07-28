
function [UpdatedCS]=EntryExitManualClassifierv2(CSstruct,index)

% Call this on a CS structure that already has dwell times embedded

if nargin<2
    index=1:size(CSstruct,2);
end

UpdatedCS=CSstruct(index);
mkdir TempClassFolder\

for i=1:size(index,2) % By contact site
    
    close all
    CS_trajPlot(CSstruct,index(i));

    %Find where binding ocurred
    bindingEvents=find(CSstruct(index(i)).trackBinding);

    % Make a struct to hold entry/exit flags
    UpdatedCS(i).NumEntry=NaN(size(CSstruct(index(i)).trackBinding));
    UpdatedCS(i).NumExit=NaN(size(CSstruct(index(i)).trackBinding));
    UpdatedCS(i).CSindex=index(i);

    for j=1:size(bindingEvents,2) %By bound trajectory

        % Highlight the track in question
        figure(1)
        set(gca, 'YDir', 'reverse')
        hold on
        traj1xy=plot(CSstruct(index(i)).CSmatrix(:,bindingEvents(j),2),CSstruct(index(i)).CSmatrix(:,bindingEvents(j),3),'LineWidth',3,'Color','r');
            %Make a dummy CS space to find segments later
            T=CSstruct(index(i)).CSmatrix(:,bindingEvents(j),1);
            X=CSstruct(index(i)).CSmatrix(:,bindingEvents(j),2);
            Y=CSstruct(index(i)).CSmatrix(:,bindingEvents(j),3);

        figure(2)
        hold on
        traj1=plot(0.011*CSstruct(index(i)).CSmatrix(:,bindingEvents(j),1),sqrt(CSstruct(index(i)).CSmatrix(:,bindingEvents(j),2).^2+CSstruct(index(i)).CSmatrix(:,bindingEvents(j),3).^2),'LineWidth',3,'Color','r');
        NumBind=CSstruct(index(i)).trackBinding(bindingEvents(j));

        % Make the class structure
        Class=cell(NumBind,1);
        NumEntry=NaN(NumBind,1);
        NumExit=NaN(NumBind,1);

        for k=1:NumBind %By binding interaction
            %Highlight the binding interaction
            figure(1)
            SegInd=find((T>CSstruct(index(i)).DwellTimes(bindingEvents(j)).EntryPts(k,1)/0.011).*(T<CSstruct(index(i)).DwellTimes(bindingEvents(j)).ExitPts(k,1)/0.011));
            BindSeg=plot(X(SegInd),Y(SegInd),'LineWidth',3,'Color','b');

            figure(2)
            x1=xline(CSstruct(index(i)).DwellTimes(bindingEvents(j)).EntryPts(k,1),'LineWidth',3,'Color','b');
            x2=xline(CSstruct(index(i)).DwellTimes(bindingEvents(j)).ExitPts(k,1),'LineWidth',3,'Color','b');
            TempClass=input('Classify Binding: (0-CS resident, 1-entry only, 2-exit only, 3-entry/exit, []- false positive)');
            
            if isempty(TempClass)
                Class{k,1}='false positive';
            elseif TempClass==0
                Class{k,1}='contact site confined';
                NumEntry(k)=0;
                NumExit(k)=0;
            elseif TempClass==1
                Class{k,1}='entry only';
                NumEntry(k)=1;
                NumExit(k)=0;
            elseif TempClass==2
                Class{k,1}='exit only';
                NumEntry(k)=0;
                NumExit(k)=1;
            elseif TempClass==3
                Class{k,1}='enter/exit';
                NumEntry(k)=1;
                NumExit(k)=1;
            else
                error('This is not an anticipated class?')
            end

            % Clear the highlighting window
            delete(x1);
            delete(x2);
            delete(BindSeg);
        end

        % Save the data
            % Record Stats in DwellTime structure
            UpdatedCS(i).DwellTimes(bindingEvents(j)).Class=Class;
            UpdatedCS(i).DwellTimes(bindingEvents(j)).EntryBool=NumEntry;
            UpdatedCS(i).DwellTimes(bindingEvents(j)).ExitBool=NumExit;
            UpdatedCS(i).DwellTimes(bindingEvents(j)).DwellTimes=UpdatedCS(i).DwellTimes(bindingEvents(j)).ExitPts-UpdatedCS(i).DwellTimes(bindingEvents(j)).EntryPts;

            % Record the summary in CS main frame
            UpdatedCS(i).NumEntry(bindingEvents(j))=sum(NumEntry,"all");
            UpdatedCS(i).NumExit(bindingEvents(j))=sum(NumExit,"all");
        % Delete the highlight/clear the graph
        delete(traj1);
        delete(traj1xy);

    end

    % Generate a temporary backup on the hard drive
    A=UpdatedCS(i);
    save(fullfile(pwd,'TempClassFolder',strcat('CS_', num2str(index(i)),'.mat')),"A");

end

% Easier in practice to do this manually
% UpdatedCS=orderfields(UpdatedCS, [1:3 26 4 11 22 24 25 5 7 6 10 8 9 12:19 21 23 20]);
% save('VAPB_CS_final.mat',"UpdatedCS");

end


