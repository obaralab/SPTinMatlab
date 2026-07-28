
% Contact Site Mapper, Full
    %Run in parent directory (needs "Density", "csIDs", "Maps" folders)
    %Loads from .mat file "Tracks" in the main directory.
    
    %Snap images are (20.48/imGpixDimensions)*60 (=60*SF) micron squares

    %Input Parameters:
        
close all    
load('Tracks.mat');
mkdir CSdata;
mkdir TrackData;

for i=1:size(Tracks,2)
    
    %Incorporate JBM data into Track Structure
    CellTracks=Tracks(i);
    %load(fullfile(pwd,'Maps',strcat('Maps_',CellTracks.file,'_kmeans_60_nb_min_30.mat')));
    %CellTracks=AssimilateTessIndex3(CellTracks,1,Maps);
    filebase=cellBase(CellTracks.file);
    
    save(fullfile(pwd,'TrackData',strcat(filebase,'_Tracks.mat')),'CellTracks');
    
    %Import List + Locations of CSs + Full Cell Image
    csFile=fullfile(pwd,'csIDs',strcat(filebase,'_CSsites.txt'));
    if exist(csFile,'file')~=2, CSlist=[]; else, CSlist=importdata(csFile); end
    % A cell with no contact sites (missing / header-only CSsites file: importdata
    % returns [] or a char/cell, not a struct) -> save empty CSdata and skip, so
    % one zero-CS cell doesn't abort the whole batch.
    if ~isstruct(CSlist) || ~isfield(CSlist,'data') || isempty(CSlist.data)
        warning('ContactSiteMapperNoDeff:noCS','%s: no contact sites — empty CSdata.',filebase);
        CSdata=struct('csID',{},'Tracks',{},'LocIDs',{},'center',{},'boundaries',{},'MitoFlag',{});
        save(fullfile(pwd,'TrackData',strcat(filebase,'_CSdata.mat')),'CSdata');
        continue;
    end
    imG=ChrisPrograms.loadtiff(fullfile(pwd,'Densities', strcat(CellTracks.file,'_rho.tif')));
    cfg=cs_config(); SF=cfg.SnapFOV_um/size(imG,1);
    
    %Establish the figures for saving snaps (off-screen: don't flash during a run)
    fig1=figure('Visible','off');
    hold off
    imshow(imG,'Border','tight');
    fig1.Position=[100 300 768 768];
    
%     fig2=figure(2);
%     hold off
%     fig2.Position=[800 300 768 768];
%     colormap(flipud(jet));
    
    %Define a structured array to hold the output data for the cell
    CSdata=struct('csID',[],'Tracks',[],'LocIDs',[],'center',[],'boundaries',[],'MitoFlag',[]);
        
    %Run through list and process each CS
    for j=1:size(CSlist.data,1)
        
        %Find the center
        Xpix=CSlist.data(j,4);
        Ypix=CSlist.data(j,5);
        
        %Find the bounds
        XrangePix=[Xpix-150 Xpix+150];
        YrangePix=[Ypix-150 Ypix+150];
        
        %Zoom to CS and save a snap (target the off-screen figure without raising it)
        set(0,'CurrentFigure',fig1);
        xlim(XrangePix);
        ylim(YrangePix);
        saveas(fig1, fullfile(pwd,'CSdata',strcat(filebase,'_CS_',num2str(j),'_density.tif')));
        
        %Find Tracks in this box
        X_l=CellTracks.matrix(:,:,2)>=(XrangePix(1)*SF);
        X_u=CellTracks.matrix(:,:,2)<=(XrangePix(2)*SF);
        Y_l=CellTracks.matrix(:,:,3)>=(YrangePix(1)*SF);
        Y_u=CellTracks.matrix(:,:,3)<=(YrangePix(2)*SF);
        mnID=X_l.*X_u.*Y_l.*Y_u;
        
        %Record data in structured Array
        CSdata(j).csID=j;
        CSdata(j).Tracks=find(sum(mnID,1));
        CSdata(j).LocIDs=find(mnID);
        CSdata(j).center=[Xpix*SF Ypix*SF];
        CSdata(j).boundaries.x=(XrangePix*SF);
        CSdata(j).boundaries.y=(YrangePix*SF);
        
        %If there are no CS labelss, do not classify the Contact sites as
        %having any association with mitochondria.
        if size(CSlist.data,2)==6
            CSlist.data(:,7:8)=2*ones(size(CSlist.data,1),2);
        end
        
        %Classify the contact sites
        if CSlist.data(j,7)==1
            CSdata(j).MitoFlag=true;
        elseif CSlist.data(j,7)==2
            CSdata(j).MitoFlag=false;
        else
            error('The input data is not lined up correctly.');
        end
        
        %Establish variables for linear indexing
            A=CellTracks.matrix(:,:,2);
            B=CellTracks.matrix(:,:,3);
%             C=CellTracks.Deff; 
        
%         figure(2);    
%         scatter(A(CSdata(j).LocIDs),B(CSdata(j).LocIDs),[],C(CSdata(j).LocIDs));
%         xlim(CSdata(j).boundaries.x);
%         ylim(CSdata(j).boundaries.y);
%         caxis([min(C(CSdata(j).LocIDs),[],'all')-0.025 max(C(CSdata(j).LocIDs),[],'all')+0.025]);
%         colorbar
%         saveas(fig2, fullfile(pwd,'CSdata',strcat(filebase,'_CS_',num2str(j),'_Deff.tif')));
        
    end

    save(fullfile(pwd,'TrackData',strcat(filebase,'_CSdata.mat')),'CSdata');

    % Close the working snapshot figure so it does not linger as a dead
    % "Figure 1" after the stage completes.
    if exist('fig1','var') && isgraphics(fig1)
        close(fig1);
    end

end
