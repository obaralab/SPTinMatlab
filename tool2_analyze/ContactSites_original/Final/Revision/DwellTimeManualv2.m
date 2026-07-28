function [CSdwellTimes] = DwellTimeManualv2(CSstruct,index,TrackStruct)
% Measure the dwell time of a trajectory by hand

if nargin<2
    index=1:size(CSstruct,2);
end

% Generate a hard disk backup
mkdir TempFolder

CSdwellTimes=struct('csID',[],'trackBinding',[],'DwellTimesData',[]);

for i=1:size(index,2)
    close all
    CS_trajPlotv2(CSstruct,index(i));
    if exist('TrackStruct', 'var')
        Label_CS_DensityPlot(TrackStruct(CSstruct(index(i)).cellIndex),CSstruct(index(i)));
        set(gcf, "Position", [100 800 700 700])
    end
   
    %Record which CS we do this loop
    CSdwellTimes(i).csID=index(i);
    
    % Allocate memory for new fields
    trackBinding=NaN(1,size(CSstruct(index(i)).tracks,2));
    trackDwellTimes=struct('trackID',[],'EntryPts',[],'ExitPts',[],'DwellTimes',[]);

    for j=1:size(CSstruct(index(i)).tracks,2)

        % Highlight the track in question
        figure(1)
        set(gca, 'YDir', 'reverse')
        hold on
        traj1xy=plot(CSstruct(index(i)).CSmatrix(:,j,2),CSstruct(index(i)).CSmatrix(:,j,3),'LineWidth',3,'Color','r');

        figure(2)
        hold on
        traj1=plot(0.011*CSstruct(index(i)).CSmatrix(:,j,1),sqrt(CSstruct(index(i)).CSmatrix(:,j,2).^2+CSstruct(index(i)).CSmatrix(:,j,3).^2),'LineWidth',3,'Color','r');

        % Ask how many binding events and mark them
        NumInteractions=input('How many binding events?');
            if isempty(NumInteractions)
                NumInteractions=0;
                EntryPts=[];
                ExitPts=[];
            else
                EntryPts=NaN(NumInteractions,2);
                ExitPts=NaN(NumInteractions,2);
                for k=1:NumInteractions
                    disp(['Enter Entry Point ' num2str(k)])
                    roi1=drawpoint;
                    EntryPts(k,1)=roi1.Position(1);
                    EntryPts(k,2)=roi1.Position(2);

                    disp(['Enter Exit Point ' num2str(k)])
                    roi2=drawpoint;
                    ExitPts(k,1)=roi2.Position(1);
                    ExitPts(k,2)=roi2.Position(2);
                end
            end

        % Store the data
        trackBinding(j)=NumInteractions;
        trackDwellTimes(j).trackID=CSstruct(index(i)).tracks(j);
        trackDwellTimes(j).EntryPts=EntryPts;
        trackDwellTimes(j).ExitPts=ExitPts;
        if ~isempty(EntryPts)
            trackDwellTimes(j).DwellTimes=ExitPts(:,1)-EntryPts(:,1);
        else

            trackDwellTimes(j).DwellTimes=[];
        end
        %trackDwellTimes(j).NetDrift=ExitPts(2,:)-EntryPts(2,:);
            %Good idea but need to orient to radial direction or number
            %will be skewed by angle
        
        % Delete the highlight/clear the graph
        delete(traj1);
        delete(traj1xy);
        clear("roi1");
        clear("roi2");

    end

    %Record CS dwell data in larger structure
    CSdwellTimes(i).trackBinding=trackBinding;
    CSdwellTimes(i).DwellTimesData=trackDwellTimes;
    save(fullfile(pwd,'TempFolder',['CS_',num2str(index(i)),'.mat']), 'trackBinding',"trackDwellTimes");

end

save('DwellTimes.mat',"CSdwellTimes");

end