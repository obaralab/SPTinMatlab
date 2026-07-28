
function CS=CS_builderNoJBM(Tracks)

    counter=0;
    CS=struct('file',[],'cellIndex',[],'csID',[],'tracks',[],'refCenter',[],...
        'boundaries',[],'refboundary',[],'refLocIDs',[],'neighborIDs',[],...
        'EllipseFit',[],'tracksCCids',[],'CSmatrix',[],'CSvec',[],'Deff',[],'segIDs',[],...
        'ChPts',[],'TessIndex',[],'refDeff',[],'neighborDeff',[],'MitoFlag',[],...
        'IDmatrixCSspec',[]);
    
    mkdir CSdata2    

    for i=1:size(Tracks,2)
        
        filename=(Tracks(i).file);
        filebase=cellBase(filename);
        csfile=fullfile(pwd,'CSdata',strcat(filebase,'_CSdata.mat'));
        if exist(csfile,'file')~=2
            % Cell had no contact sites (skipped in picking/refining) -> no CSdata file was
            % ever written. Omit it from CS_final instead of erroring; cellIndex (i) stays
            % correct for every cell that DOES have sites.
            warning('CS_builder:noCSdata','%s: no CSdata (cell skipped) — omitting from CS_final.', filebase);
            continue;
        end
        load(csfile,'CSdata');

        for j=1:size(CSdata,2)
            
           counter=counter+1; 
           CSdata(j).cellIndex=i;
           CSdata(j).csIndex=counter;
           
           CS(counter).file=Tracks(i).file;
           CS(counter).cellIndex=i;
           CS(counter).csID=CSdata(j).csID;
           CS(counter).tracks=CSdata(j).Tracks;
           CS(counter).refCenter=CSdata(j).refCenter;
           CS(counter).boundaries=CSdata(j).boundaries;
           CS(counter).refboundary=CSdata(j).refboundary;
           CS(counter).refLocIDs=CSdata(j).refLocIDs;
           CS(counter).neighborIDs=setdiff(CSdata(j).LocIDs,CSdata(j).refLocIDs);
                %these are inside boundaries but outside refboundary
           CS(counter).EllipseFit=CSdata(j).EllipseFit;
           if isfield(Tracks,'CCindex') && ~isempty(Tracks(i).CCindex)
               CS(counter).tracksCCids=mean(Tracks(i).CCindex(:,CSdata(j).Tracks),1,'omitnan');
           else
               CS(counter).tracksCCids=zeros(1,numel(CSdata(j).Tracks));  % no NPB (ChrisC) data
           end
           CS(counter).CSmatrix=cat(3,Tracks(i).matrix(:,CSdata(j).Tracks,1),...
               Tracks(i).matrix(:,CSdata(j).Tracks,2)-CSdata(j).refCenter(1),...
               Tracks(i).matrix(:,CSdata(j).Tracks,3)-CSdata(j).refCenter(2));
                %same layout as usual matrix, but centered at refcenter and
                %only tracks involved in CS
           CS(counter).CSvec=Tracks(i).vector(:,CSdata(j).Tracks,:);
                %vectors for the same tracks
%            CS(counter).Deff=Tracks(i).Deff(:,CSdata(j).Tracks);
                %Deff in the same M and N space
           if isfield(Tracks,'cp') && ~isempty(Tracks(i).cp)
               CS(counter).ChPts=Tracks(i).cp(:,CSdata(j).Tracks);
           else
               % no NPB changepoints: zeros matching frames x nTracks so the
               % accumulator's ChPts.*IDmatrixCSspec broadcast still works
               CS(counter).ChPts=zeros(size(Tracks(i).matrix(:,CSdata(j).Tracks,1)));
           end
           if isfield(Tracks,'segID') && ~isempty(Tracks(i).segID)
               CS(counter).segIDs=Tracks(i).segID(:,CSdata(j).Tracks);
           else
               CS(counter).segIDs=[];                                     % no NPB segment IDs
           end
%            CS(counter).TessIndex=Tracks(i).LocIndex(:,CSdata(j).Tracks);
                %JBM tesselation loc is assigned to
%            CS(counter).refDeff=Tracks(i).Deff(CSdata(j).refLocIDs);
                %Deff of locs in refboundary as a list
%            CS(counter).neighborDeff=Tracks(i).Deff(CS(counter).neighborIDs);
                %Deff of locs outside refboundary as a list
           CS(counter).MitoFlag=CSdata(j).MitoFlag;
                %Mito associated?
                
                
           % Make a matrix the same size as the cropped M & N space that
           % defines 1 if a localization is "neighborhood" and 2 if a
           % localization is "ContactSite".
           DummyMatrix1=zeros(size(Tracks(i).matrix(:,:,1)));
           DummyMatrix1(CS(counter).neighborIDs)=1;
           DummyMatrix1(CSdata(j).refLocIDs)=2;
           CS(counter).IDmatrixCSspec=DummyMatrix1(:,CSdata(j).Tracks);
        end
        
        save(fullfile(pwd,'CSdata2',strcat(filebase,'_CSdata2.mat')),'CSdata');
        
        
    end

    save('CS_final.mat','CS');

end