
function OutStruct=CoordShiftCS(CSstruct,index,alphadeg,origin)

    %NOTE: COUNTERCLOCKWISE is Positive (Right hand rule)
        % This function operates on new CS structured arrays
        
        % Do NOT run this iteratively on the same data--always combine the
        % processes into the input vraibles, or it will not record all the
        % steps it has performed in the array.
        
        
if nargin==3
    origin=[0 0];
end

OutStruct=CSstruct(index);

%Record the change that has been applied
OutStruct.file=strcat(CSstruct(index).file,'_CoordShift');
OutStruct.origin=origin;
OutStruct.alpha=alphadeg;

%Prepare the raw data
% Move to the origin before rotating
TempX(:,:)=OutStruct.CSmatrix(:,:,2)-origin(1);
TempY(:,:)=OutStruct.CSmatrix(:,:,3)-origin(2);

% Rotate by angle alpha in degrees
OutStruct.CSmatrix(:,:,2)=TempX*cosd(alphadeg)-TempY*sind(alphadeg);
OutStruct.CSmatrix(:,:,3)=TempX*sind(alphadeg)+TempY*cosd(alphadeg);

% Rotate the CSvectors
TempX2(:,:)=OutStruct.CSvec(:,:,1);
TempY2(:,:)=OutStruct.CSvec(:,:,2);

OutStruct.CSvec(:,:,1)=TempX2*cosd(alphadeg)-TempY2*sind(alphadeg);
OutStruct.CSvec(:,:,2)=TempX2*sind(alphadeg)+TempY2*cosd(alphadeg);

%Rotate the boundaries
% Centered Boundaries
TempBounds=OutStruct.boundaries.centered;
TempBounds(:,1)=TempBounds(:,1)-origin(1);
TempBounds(:,2)=TempBounds(:,2)-origin(2);
OutStruct.boundaries.centered=[TempBounds(:,1)*cosd(alphadeg)-TempBounds(:,2)*sind(alphadeg), TempBounds(:,1)*sind(alphadeg)+TempBounds(:,2)*cosd(alphadeg)];

% Refined Boundaries
TempBounds=OutStruct.boundaries.refBoundary;
TempBounds(:,1)=TempBounds(:,1)-origin(1);
TempBounds(:,2)=TempBounds(:,2)-origin(2);
OutStruct.boundaries.refBoundary=[TempBounds(:,1)*cosd(alphadeg)-TempBounds(:,2)*sind(alphadeg), TempBounds(:,1)*sind(alphadeg)+TempBounds(:,2)*cosd(alphadeg)];

% Ellipse Fit
   TempCentroid=OutStruct.EllipseFit.Centroid-origin;
   OutStruct.EllipseFit.Centroid=[TempCentroid(1)*cosd(alphadeg)-TempCentroid(2)*sind(alphadeg), TempCentroid(1)*sind(alphadeg)+TempCentroid(2)*cosd(alphadeg)];
   OutStruct.EllipseFit.Orientation=OutStruct.EllipseFit.Orientation+alphadeg;
    

end