function [n_best P_best V]=fast_oopsi(F,V,P)
% this function solves the following optimization problem:
% (*) n_best = argmax_{n >= 0} P(n | F)
% which is a MAP estimate for the most likely spike train given the
% fluorescence signal.  given the model:
%
% C_t = gam*C_{t-1} + n_t,      n_t ~ Poisson(n_t; lam_t)
% F_t = a*C_t + b + sig*eps_t,  eps_t ~ N(0,1)
%
% if F_t is a vector, then 'a' is a vector as well
% we approx the Poisson with an Exponential (which means we don't require integer numbers of spikes).
% we take an "interior-point" approach to impose the nonnegative contraint on (*). 
% each step is solved in O(T)
% time by utilizing gaussian elimination on the tridiagonal hessian, as
% opposed to the O(T^3) time typically required for non-negative
% deconvolution.
%
% Input---- only F is REQUIRED.  the others are optional
% F:        fluorescence time series (can be a vector (1 x T) or a matrix (Np x T)
%
% V.        structure of algorithm Variables
%   T:      # of time steps
%   dt:     time step size
%   Np:     # of pixels in ROI
%   Nc:     # of cells within ROI
%   Poiss:  whether observations are assumed to come from a Poisson or Gaussian distribution
%   fast_iter_max:  maximum number of iterations of pseudo-EM   (typically set to 50)
%
%   THE FOLLOWING FIELDS CORRESPOND TO CHOICES THAT THE USER MAKE
%
%   fast_plot:  whether to plot results (only required is est_a==1)
%   fast_thr:   whether to threshold infered spike train before updating 'a' and 'b' (only required is est_a==1)
%   n:          if true spike train is known, and we are plotting, plot it (only required is est_a==1)
%   h:          height of ROI (assumes square ROI) (# of pixels) (only required if est_a==1 and we are plotting)
%   w:          width of ROI (assumes square ROI) (# of pixels) (only required if est_a==1 and we are plotting)
%
%   THE BELOW FIELDS INDICATE WHETHER ONE WANTS TO ESTIMATE EACH OF THE
%   PARAMETERS
%
%   est_sig:    whether to estimate sig? (default 1)
%   est_lam:    whether to estimate lam? (default 1)
%   est_gam:    whether to estimate gam? (default 0)
%   est_b:      whether to estimate b?   (default 1)
%   est_a:      whether to estimate a?   (default 1)
%
% P.        structure of neuron Model parameters
%
%   a:      spatial filter
%   b:      baseline
%   sig:    standard deviation
%   gam:    decayish (ie, tau=dt/(1-gam)
%   lam:    firing rate-ish
%
% Output---
% n_best:   inferred spike train
% P_best:   inferred parameter structure
% V:        structure of Variables for algorithm to run

%% initialize algorithm Variables
starttime = cputime;
% set meta parameter values
if nargin < 2,          V       = struct;       end
if isfield(V,'Poiss'),  Poiss   = V.Poiss;      else Poiss  = 0; end    % whether observations are Poisson
if isfield(V,'Nc'),     Nc      = V.Nc;         else Nc     = 1; end    % # of cells in image
if isfield(V,'Np') && isfield(V,'T'), Np = V.Np; T = V.T;               % # of pixels and image frames
else numelF=numel(F);   lenF=length(F);     sizF = size(F);             % assumes F is Np x T
    if numelF == lenF,  Np = 1; T=numelF;                               % set Np and T when F is a vector
        if sizF(1)>1; F=F'; end                                         % makes F be 1 x T
    else Np = sizF(1); T=sizeF(2);
    end
end
if ~isfield(V,'T'),     V.T = length(F);        end                     % # of time steps
if isfield(V,'dt'),     dt = V.dt;              else                    % frame rate
    fr = input('what was the frame rate for this movie (in Hz)? ');
    dt = 1/fr; V.dt = dt;
end
if isfield(V,'fast_iter_max'), fast_iter_max = V.fast_iter_max;   else
    reply = input('do you want to estimate parameters? y/n [y] (case sensitive): ', 's');
    if reply == 'y'; fast_iter_max = 10;
    else fast_iter_max = 0; end
end
if ~isfield(V,'fast_plot'),  V.fast_plot=1;   end
if V.fast_plot==1
    FigNum = 400;
    if Np>1, figure(FigNum), clf, end                                   % figure showing estimated spatial filter
    figure(FigNum+1), clf                                               % figure showing estimated spike trains
end

% set which parameters to estimate
if fast_iter_max>1;
    if ~isfield(V,'est_sig'),   V.est_sig   = 1; end
    if ~isfield(V,'est_lam'),   V.est_lam   = 1; end
    if ~isfield(V,'est_gam'),   V.est_gam   = 0; end
    if ~isfield(V,'est_a'),     V.est_a     = 0; end
    if ~isfield(V,'est_b'),     V.est_b     = 1; end
    if ~isfield(V,'fast_plot'), V.fast_plot = 1; end
    if ~isfield(V,'fast_thr'),  V.fast_thr  = 1; end
else
    V.est_a=1;
end


%% set default model Parameters

if nargin < 3,          P       = struct;   end
if ~isfield(P,'b'),     P.b     = mean(F);  end
if ~isfield(P,'sig'),   P.sig   = std(F);   end
if ~isfield(P,'gam'),   P.gam   = 1-V.dt/1; end
if ~isfield(P,'lam'),   P.lam   = 10;       end
if ~isfield(P,'a'),     P.a     = 1;        end

%% define some stuff needed for FastFilter function

% make sure we have 1 spatial filter per neuron in ROI
siz=size(P.a);
if V.est_a==1
    if siz(2)~=Nc
        [U,S,V]=pca_approx(F',Nc);
        for j=1:Nc, P.a(:,j)=V(:,j); end
    else
        P.a=ones(Nc,1);
    end
end
if isfield(V,'n'),
    V.n(isnan(V.n))=0;
    siz=size(V.n); if siz(1)<siz(2), V.n=V.n'; end;
end

Z   = zeros(Nc*T,1);                            % zero vector
M   = spdiags([repmat(-P.gam,T,1) repmat(Z,1,Nc-1) (1+Z)], -Nc:0,Nc*T,Nc*T);  % matrix transforming calcium into spikes, ie n=M*C
I   = speye(Nc*T);                              % create out here cuz it must be reused
d0  = 1:Nc*T+1:(Nc*T)^2;                        % index of diagonal elements of TxT matrices
d1  = 1+Nc:Nc*T+1:(Nc*T)*(Nc*(T-1));            % index of off-diagonal elements of TxT matrices
l   = Z(1:fast_iter_max);                             % initialize likelihood
if numel(P.lam)==Nc
    lam = dt*repmat(P.lam,T,1);                 % for lik
elseif numel(P.lam)==Nc*T
    lam = dt*P.lam;
else
    error('lam must either be length T or 1');
end

if Poiss==1
    H       = I;                                % initialize memory for Hessian matrix
    gamlnF  = gammaln(F+1);                     % for lik
    sumF    = sum(F);                           % for Hess
else
    H1  = I;                                    % initialize memory for Hessian matrix
    H2  = I;                                    % initialize memory for Hessian matrix
end


%% infer spike train using default/initialized parameters
[n C] = FastFilter(F,P);

%%  if parameters are unknown, do pseudo-EM iterations
if fast_iter_max>1
    
    % set up stuff
    D       = F-P.a*(reshape(C,Nc,T)+b);            % required to compute initial likelihood
    mse     = -D(:)'*D(:);                          % required to compute initial likelihood
    l(1)    = -T*Np*log(2*pi*P.sig^2)/2 - mse/(2*P.sig^2); % initial likelihood
    l_max   = l(1);                                 % maximum likelihood achieved so far
    n_best  = n;                                    % best spike train
    P_best  = P;                                    % best parameter estimate
    options = optimset('Display','off');            % don't show warnings for parameter estimation
    i       = 1;                                    % iteration #
    i_best  = i;                                    % iteration with highest likelihood
    conv    = 0;                                    % whether algorithm has converged yet

    while conv == 0

        if V.fast_plot == 1, MakePlot(n,F,P,V); end % plot results from previous iteration
        i       = i+1;                              % update iteratation number
        V.fast_iter_tot = i;                        % record of total # of iterations
        P       = ParamUpdate(n,C,F,P,b);           % update parameters based on previous iteration
        [n C]   = FastFilter(F,P);                  % update inferred spike train based on new parameters

        if l(i)>l_max                               % if this is the best one, keep n and P
            n_best  = n;                            % keep n
            P_best  = P;                            % keep P
            i_best  = i;                            % keep track of which was best
            l_max   = l(i);                         % keep max posterior
        end

        if conv == 1, disp('convergence criteria met'), break; end
        sound(3*sin(linspace(0,90*pi,2000)))        % play sound to indicate iteration is over
    end
    P_best.l=l(1:i);                                % keep record of likelihoods for record
else                                                % if not iterating, just output stuff from 1st run
    n_best = n;
    P_best = P;
    V.fast_iter_tot = 1;
end
V.fast_time = cputime-starttime;                    % time to run code
V           = orderfields(V);                       % order fields alphabetically to they are easier to read
P_best      = orderfields(P_best);

%% fast filter function
    function [n C DD] = FastFilter(F,P)

        % initialize n and C
        z = 1;                                  % weight on barrier function
        e = 1/(2*P.sig^2);                      % scale of variance
        llam = reshape(1./lam',1,Nc*T)';
        n = z.*llam;                            % initialize spike train
        C = 0*n;                                % initialize calcium
        for j=1:Nc
            C(j:Nc:end) = filter(1,[1, -P.gam(j)],n(j:Nc:end)) + (1-P.gam(j))*P.b(j);
        end

        % precompute parameters required for evaluating and maximizing likelihood
        b           = repmat(P.b,T,1)';         % for lik
        if Poiss==1
            suma    = sum(P.a);                 % for grad
        else
            aF      = P.a'*F;                   % for grad
            bb      = b(:);                     % for grad
            M(d1)   = -repmat(P.gam,T-1,1);     % matrix transforming calcium into spikes, ie n=M*C
            lnprior = llam.*sum(M)';            % for grad
            aa      = repmat(diag(P.a'*P.a),T,1);% for grad
            H1(d0)  = 2*e*aa;                   % for Hess
        end

        % find C = argmin_{C_z} lik + prior + barrier_z
        while z>1e-13                           % this is an arbitrary threshold

            if Poiss==1
                Fexpected = P.a*(C+b')';        % expected poisson observation rate
                L = sum(sum(exp(-Fexpected+ F.*log(Fexpected) - gamlnF)));
            else
                D = F-P.a*(reshape(C,Nc,T)+b);  % difference vector to be used in likelihood computation
                L = e*D(:)'*D(:)+llam'*n-z*sum(log(n));% Likilihood function using C
            end
            s = 1;                              % step size
            d = 1;                              % direction
            while norm(d)>5e-2 && s > 1e-3      % converge for this z (again, these thresholds are arbitrary)
                if Poiss==1
                    g   = (-suma + sumF./(C+b')')';
                    H(d0) = sumF'.*(C+b').^(-2);
                else
                    g   = 2*e*(aa.*(C+bb)-aF(:)) + lnprior - z*M'*(n.^-1);  % gradient
                    H2(d0) = n.^-2;             % part of the Hessian
                    H   = H1 + z*(M'*H2*M);     % Hessian
                end
                d   = -H\g;                     % direction to step using newton-raphson
                hit = -n./(M*d);                % step within constraint boundaries
                hit(hit<0)=[];                  % ignore negative hits
                if any(hit<1)
                    s = min(1,0.99*min(hit(hit>0)));
                else
                    s = 1;
                end
                L1 = L+1;
                while L1>=L+1e-7                % make sure newton step doesn't increase objective
                    C1  = C+s*d;
                    n   = M*C1;
                    if Poiss==1
                        Fexpected = P.a*(C1+b')';
                        L1 = sum(sum(exp(-Fexpected + F.*log(Fexpected) - gamlnF)));
                    else
                        D   = F-P.a*(reshape(C1,Nc,T)+b);
                        DD  = D(:)'*D(:);
                        L1  = e*DD+llam'*n-z*sum(log(n));
                    end
                    s   = s/5;                  % if step increases objective function, decrease step size
                    if s<1e-20; 
                        disp('reducing s further did not increase likelihood'), break; end      % if decreasing step size just doesn't do it
                end
                C = C1;                         % update C
                L = L1;                         % update L
            end
            z=z/10;                             % reduce z (sequence of z reductions is arbitrary)
        end

        % reshape things in the case of multiple neurons within the ROI
        n=reshape(n,Nc,T)';
        C=reshape(C,Nc,T)';
    end

%% Parameter Update
    function P = ParamUpdate(n,C,F,P,b)

        % generate regressor for spatial filter
        if V.est_a==1 || V.est_b==1
            if V.fast_thr==1
                CC=0*C;
                for j=1:Nc
                    nsort   = sort(n(:,j));
                    nthr    = nsort(round(0.98*T));
                    nn      = Z(1:T);
                    nn(n(:,j)<=nthr)=0;
                    nn(n(:,j)>nthr)=1;
                    CC(:,j) = filter(1,[1 -P.gam(j)],nn) + (1-P.gam(j))*P.b(j);
                end
            else
                CC      = C;
            end

            % update spatial filter and baseline
            CC = CC + b';
            if V.est_a==1
                for ii=1:Np
                    Y   = F(ii,:)';
                    P.a(ii,:) = CC\Y;
                end
            end
            if V.est_b==1
                if Np>1
                    P.b     = quadprog(P.a'*P.a,-P.a'*sum(F - P.a*CC',2)/T',[],[],[],[],Z(1:Nc),inf+Z(1:Nc),P.b,options);
                    P.b     = P.b';
                else
                    P.b = mean(F-P.a*C');
                    P.b(P.b<0)=0;
                end
            end
            b       = repmat(P.b,T,1)';
            D       = F-P.a*(reshape(C,Nc,T)+b);
            mse     = -D(:)'*D(:);
        end

        if V.est_a==0 && V.est_b==0 && (V.est_sig==1 || V.est_lam==1), D = F-P.a*(reshape(C,Nc,T)+b); mse = -D(:)'*D(:); end

        % estimate other parameters
        if V.est_sig==1,
            P.sig = sqrt(-mse)/T;
        end
        if V.est_lam==1,
            nnorm   = n./repmat(max(n),T,1);
            if numel(P.lam)==Nc
                P.lam   = sum(nnorm)'/(T*dt);
                lam     = repmat(P.lam,T,1)*dt;
            else
                P.lam   = nnorm/(T*dt);
                lam     = P.lam*dt;
            end

        end

        % update likelihood and keep results if they improved
        lik     = -T*Np*log(2*pi*P.sig^2)/2 - mse/(2*P.sig^2);
        prior   = sum(lam(:)) - lam(:)'*n(:);
        l(i)    = lik + prior;

        % if lik doesn't change much (relatively), or returns to some previous state, stop iterating
        if  i>=fast_iter_max || (abs((l(i)-l(i-1))/l(i))<1e-5 || any(l(1:i-1)-l(i))<1e-5)% abs((l(i)-l(i-1))/l(i))<1e-5 || l(i-1)-l(i)>1e5;
            conv = 1;
        end

    end

%% MakePlot
    function MakePlot(n,F,P,V)
        if V.fast_plot == 1
            if Np>1                                     % plot spatial filter
                figure(FigNum), nrows=Nc;
                for j=1:Nc, subplot(1,nrows,j),
                    imagesc(reshape(P.a(:,j),V.h,V.w)),
                    title('a')
                end
            end

            figure(FigNum+1),  ncols=Nc; nrows=3; END=T;
            for j=1:Nc                                  % plot inferred spike train
                h(j,1)=subplot(nrows,ncols,j); cla
                if Np>1, Ftemp=mean(F); else Ftemp=F; end
                plot(z1(Ftemp(2:END))+1), hold on,
                bar(z1(n_best(2:END,j)))
                title(['best iteration ' num2str(i_best)]),
                axis('tight')

                h(j,2)=subplot(nrows,ncols,j+1);
                bar(z1(n(2:END,j)))
                if isfield(V,'n'), hold on,
                    stem(V.n(2:END,j),'LineStyle','none','Marker','v','MarkerEdgeColor','k','MarkerFaceColor','k','MarkerSize',2)
                end
                set(gca,'XTickLabel',[])
                title(['current iteration ' num2str(i)]),
                axis('tight')

            end

            subplot(nrows,ncols,j*nrows),
            plot(l(1:i))    % plot record of likelihoods
            title(['max lik ' num2str(l_max,4), ',   lik ' num2str(l(i),4)])
            set(gca,'XTick',2:i,'XTickLabel',2:i)
            drawnow
        end
    end
end