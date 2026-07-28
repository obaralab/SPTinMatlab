
% AvgAccumulator

function CSfull=AvgCSAccumulator(CS)

%Allocate space for recording the size of each CSmatrix and the length of
%each CS boundary
m=NaN(size(CS));
n=NaN(size(CS));
bl=NaN(size(CS));

for i=1:size(CS,2)
    m(i)=size(CS(i).Deff,1);
    n(i)=size(CS(i).Deff,2);
    bl(i)=size(CS(i).refboundary,1);
end

%Establish the memory you will need to assemble everything
MaxBL=max(bl,[],'all');
MaxM=max(m,[],'all');
NumTracks=sum(n,'all');

%Allocate the memory
Boundaries=NaN(MaxBL,size(CS,2),2);

FullMatrix=NaN(MaxM,NumTracks,2);
ChPts=NaN(MaxM,NumTracks);
Deff=NaN(MaxM,NumTracks);
Vecs=NaN(MaxM-1,NumTracks,2);
DeffNorm=NaN(MaxM,NumTracks);

n=[0 n];

for i=1:size(CS,2)
    %Define a sliding variable to define the fused N-coordinates
    X=(sum(n(1:i),'all')+1):(sum(n(1:i),'all')+n(i+1));
    
    %Record the boundaries into a matrix, x is 1 in 3rd dimension, y is a 2
    smBound=[CS(i).refboundary(end-3:end,:); CS(i).refboundary; CS(i).refboundary(1:4,:)];
    smBound=smoothdata(smBound,1,'movmean',5);
    Boundaries(1:size(CS(i).refboundary,1),i,:)=permute(smBound(5:end-4,:),[1 3 2]);
    
    %Record the M and N space variables into a fused M and N space
    FullMatrix(1:size(CS(i).CSmatrix,1),X,:)=CS(i).CSmatrix(:,:,2:3);
    ChPts(1:size(CS(i).CSmatrix,1),X)=CS(i).ChPts;
    Deff(1:size(CS(i).CSmatrix,1),X)=CS(i).Deff;
    Vecs(1:(size(CS(i).CSmatrix,1)-1),X,:)=CS(i).CSvec(:,:,:);
    
    %Calculate the Relative Deff
    DeffNorm(1:size(CS(i).CSmatrix,1),X)=CS(i).Deff/mean(CS(i).refDeff,'all','omitnan');
       
end

CSfull=struct('matrix',FullMatrix,'boundaries',Boundaries,'ChPts',ChPts,'vector',Vecs,'D',Deff,'normD',DeffNorm);

end