
function CS2=Reorganize(CS1)

    CS2=struct('file',[],'globalID',[],'cellIndex',[],'csID',[],...
        'tracks',[],'trackCCids',[],'refCenter',[],...
        'boundaries',[],'EllipseFit',[],'CSmatrix',[],'CSvec',[],...
        'IDs',[],'Deff',[],'MitoFlag',[]);
    
    for i=1:size(CS1,2)
        
       CS2(i).file=cellBase(CS1(i).file);
       %    Reset filename to filebase for compatibility
       CS2(i).globalID=i;
       %    global ID within condition structures
       CS2(i).cellIndex=CS1(i).cellIndex;
       %    cell index where data comes from in TrackStruct
       CS2(i).csID=CS1(i).csID;
       %    Contact Site ID within the cell
       CS2(i).tracks=CS1(i).tracks;
       %    TrackIDs involved within the cell
       CS2(i).trackCCids=CS1(i).tracksCCids;
       %    IDs from ChrisC double-blinded analysis
       CS2(i).refCenter=CS1(i).refCenter;
       %    Center after manual refinement
       CS2(i).boundaries.orig.x=CS1(i).boundaries.x;
       CS2(i).boundaries.orig.y=CS1(i).boundaries.y;
       %    Original boundaries of square within image
       
       CS2(i).boundaries.centered=[CS1(i).boundaries.x(1)-CS2(i).refCenter(1), ...
           CS1(i).boundaries.y(1)-CS2(i).refCenter(2); CS1(i).boundaries.x(2)-...
           CS2(i).refCenter(1), CS1(i).boundaries.y(1)-CS2(i).refCenter(2);...
           CS1(i).boundaries.x(2)-CS2(i).refCenter(1), CS1(i).boundaries.y(2)-...
           CS2(i).refCenter(2); CS1(i).boundaries.x(1)-CS2(i).refCenter(1),...
           CS1(i).boundaries.y(2)-CS2(i).refCenter(2); CS1(i).boundaries.x(1)-...
           CS2(i).refCenter(1), CS1(i).boundaries.y(1)-CS2(i).refCenter(2)];
       % Center original boundaries and give coordinates of endpoints for
       % plotting (5 x 2 mstrix)
       
       CS2(i).boundaries.refBoundary=CS1(i).refboundary/1000;
       % refBoundary in microns
       
       %Ellipse Fit
       CS2(i).EllipseFit.Centroid=0.03*(CS1(i).EllipseFit.Centroid-[31 31]);
       CS2(i).EllipseFit.MajorAxisLength=0.03*CS1(i).EllipseFit.MajorAxisLength;
       CS2(i).EllipseFit.MinorAxisLength=0.03*CS1(i).EllipseFit.MinorAxisLength;
       CS2(i).EllipseFit.Orientation=CS1(i).EllipseFit.Orientation;
       
       %Raw Data
       CS2(i).CSmatrix=CS1(i).CSmatrix;
       CS2(i).CSvec=CS1(i).CSvec;
       
       %Indexes and identities
       CS2(i).IDs.refLocIDs=CS1(i).refLocIDs;
            %Linear indexes of locs in refBoundary IN THE TRACK MATRIX NOT
            %THIS ONE
       CS2(i).IDs.neighborIDs=CS1(i).neighborIDs;
            %Linear indexes of locs outside ref Boundary but inside
            %boundaries.center IN THE TRACK MATRIX NOT THIS ONE
       CS2(i).IDs.IDmatrixCSspecs=CS1(i).IDmatrixCSspec;
            %M and N space with a 1 classifier if something is a neighbor
            %and a 2 classifier if it is in the CS proper 
       CS2(i).IDs.segIDs=CS1(i).segIDs;
            %M and N space with steps that fall in ChrisC traj classified
            %by their seg number
       CS2(i).IDs.ChPts=CS1(i).ChPts;
            %M and N space with steps that are ChPts between segs logically
            %defined
       CS2(i).IDs.TessIndex=CS1(i).TessIndex;
            %M and N space with the Tesselation ID that each loc was
            %classified as listed
            
       % JBM Deff values     
       CS2(i).Deff.D=CS1(i).Deff;
       CS2(i).Deff.D_CS=CS1(i).refDeff;
       CS2(i).Deff.D_prox=CS1(i).neighborDeff;
       
       CS2(i).MitoFlag=CS1(i).MitoFlag;
      
        
    end



end