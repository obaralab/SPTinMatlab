
function CS=CS_builder_v2(Tracks)

    counter=0;
    CS=struct('file',[],'cellIndex',[],'csID',[],'tracks',[],'refCenter',[],...
        'boundaries',[],'LocIDs',[],'refboundary',[],'refLocIDs',[],'neighborIDs',[], 'CSLocIDs',[],...
        'CSneighborIDs',[],'EllipseFit',[],'tracksCCids',[],'CSmatrix',[],'CSvec',[],'Deff',[],'segIDs',[],...
        'ChPts',[],'TessIndex',[],'refDeff',[],'neighborDeff',[],'MitoFlag',[]);
    TracksIDmatrix=struct('file',[],'cellIndex',[],'IDmatrix',[],'ErrorMatrix',[]);
    
    mkdir CSdata2   

    % Check if JBM fields exist and if not fill with NaN arrays
        if ~isfield(Tracks,'JBM')
            [Tracks.JBM]=deal([]);
            for i=1:size(Tracks,2)
                Tracks(i).Deff=NaN(size(Tracks(i).matrix(:,:,1)));
                Tracks(i).LocIndex=NaN(size(Tracks(i).matrix(:,:,1)));
            end
        end

    % Then get to business
    for i=1:size(Tracks,2)
        
        filename=(Tracks(i).file);
        filebase=filename(1:end-7);
        load(fullfile(pwd,'CSdata',strcat(filebase,'_CSdata.mat')),'CSdata');
        IDmatrixMN=NaN([size(CSdata(1).IDmatrixMN) size(CSdata,2)]);

        % Check for failed entries and remove them
        if find(cellfun(@isempty,{CSdata.refCenter})) %if some indexes of structure don't have refCenter, remove them
            CSset=find(~cellfun(@isempty,{CSdata.refCenter}));
        else
            CSset=1:size(CSdata,2);
        end

        % Then establish the IDmatrix of the right size
        for j=CSset
            IDmatrixMN(:,:,j)=CSdata(j).IDmatrixMN;
        end
        
        % Generate an IDmatrix to record where ref boundaries are in M and
        % N space
        TracksIDmatrix(i).file=Tracks(i).file;
        TracksIDmatrix(i).cellIndex=i;
        TracksIDmatrix(i).IDmatrix=sum(IDmatrixMN,3,'omitnan');
        if max(TracksIDmatrix(i).IDmatrix,[],"all","omitnan")>1
            warning('Some steps overlap between Contact Sites.');
            TracksIDmatrix(i).ErrorMatrix=IDmatrixMN;
        end
        save(fullfile(pwd,'CSdata2',strcat(filebase,'_IDmatrix.mat')),"TracksIDmatrix");

        

        % Compile info about cell CSidentities and save it as a reference
        for j=CSset
            
           counter=counter+1; 
           CSdata(j).cellIndex=i;
           CSdata(j).csIndex=counter;
           
           CS(counter).file=Tracks(i).file;
           CS(counter).cellIndex=i;
           CS(counter).csID=CSdata(j).csID;
           CS(counter).tracks=CSdata(j).Tracks;
           CS(counter).refCenter=CSdata(j).refCenter;
           CS(counter).boundaries=CSdata(j).boundaries;
           CS(counter).LocIDs=CSdata(j).LocIDs; %MN-space indexes for things in boundary
           CS(counter).refboundary=smoothdata([CSdata(j).refboundary(end-10:end,:); ...
               CSdata(j).refboundary; CSdata(j).refboundary(1:10,:)],1,'movmean',10); 
           CS(counter).refLocIDs=CSdata(j).refLocIDs; %MN-space indexes for things in refBoundary
           CS(counter).CSLocIDs=CSdata(j).CSLocIDs; %CS mn-space indexes


           % I left this code here for legacy compatibility checks, but
           % don't use these any more--these are not good definitions for
           % neighbors of ID matrices--see below for updated.
%            CS(counter).neighborIDs=setdiff(find(isfinite(Tracks(i).matrix(:,CSdata(j).Tracks,1))),CSdata(j).refLocIDs);
%            CS(counter).TrackLocIDsMN=find(isfinite(Tracks(i).matrix(:,CSdata(j).Tracks,1)));
                %these are m and n space coordinates (linear index) for
                %all CS-associated tracks (i.e. refLocIDs +
                %neighboirIDs but in track m and n space rather than CS m
                %and n space)

           CS(counter).neighborIDs=setdiff(CSdata(j).LocIDs,find(logical(TracksIDmatrix(i).IDmatrix)));
                TempMatrix=zeros(size(TracksIDmatrix(i).IDmatrix));
                TempMatrix(CS(counter).neighborIDs)=1;
                TempMatrix=TempMatrix(:,CS(counter).tracks);
                %note the CS neighbors will miss neighbor loc ids that
                %aren't in the tracks within the CS structure!
           CS(counter).CSneighborIDs=find(TempMatrix);
           
           CS(counter).EllipseFit=CSdata(j).EllipseFit;
           CS(counter).tracksCCids=mean(Tracks(i).CCindex(:,CSdata(j).Tracks),1,'omitnan');
                %same size as "tracks", but zero if not fit, ChrisC ID # if
                %fit
           CS(counter).CSmatrix=cat(3,Tracks(i).matrix(:,CSdata(j).Tracks,1),...
               Tracks(i).matrix(:,CSdata(j).Tracks,2)-CSdata(j).refCenter(1),...
               Tracks(i).matrix(:,CSdata(j).Tracks,3)-CSdata(j).refCenter(2));
                %same layout as usual matrix, but centered at refcenter and
                %only tracks involved in CS
           CS(counter).CSvec=Tracks(i).vector(:,CSdata(j).Tracks,:);
                %vectors for the same tracks
           CS(counter).Deff=Tracks(i).Deff(:,CSdata(j).Tracks);
                %Deff in the same M and N space
           CS(counter).ChPts=Tracks(i).cp(:,CSdata(j).Tracks);
                %logical array for M & N space if position is a CP
           CS(counter).segIDs=Tracks(i).segID(:,CSdata(j).Tracks);
                %M & N array with segIDs for ChrisC results if position is
                %associated
           CS(counter).TessIndex=Tracks(i).LocIndex(:,CSdata(j).Tracks);
                %JBM tesselation loc is assigned to
           CS(counter).refDeff=CS(counter).Deff(CSdata(j).CSLocIDs);
                %Deff of locs in refboundary as a list
           CS(counter).neighborDeff=Tracks(i).Deff(CS(counter).neighborIDs);
                %Deff of locs outside refboundary as a list
           CS(counter).MitoFlag=CSdata(j).MitoFlag;
                %Mito associated?
                
        end

        save(fullfile(pwd,'CSdata2',strcat(filebase,'_CSdata2.mat')),'CSdata');
        
        
    end

    save('CS_final_v2.mat','CS');

end