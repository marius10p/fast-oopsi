function [n_best P_best]=FOOPSI2_59(F,P,Sim)
% this function solves the following optimization problem:
% n_best = argmax_{n >= 0} P(n | F)
% which is a MAP estimate for the most likely spike train given the
% fluorescence signal.  given the model:
%
% F_t = alpha*C_t + beta + sigma*eps_t, eps_t ~ N(0,1)
% C_t = gam C_{t-1} + nu + rho*n_t, n_t ~ Poisson(n_t; p_t)
%
% and we approx the Poisson with an Exponential. we take an
% "interior-point" approach. each step with solved in O(T)
% time by utilizing gaussian elimination on the tridiagonal hessian, as
% opposed to the O(T^3) time typically required for non-negative
% deconvolution.
%
% Input----
% F:        fluorescence time series
% P.        structure of neuron parameters
%   alpha:  scale
%   beta:   offset
%   sig:    standard deviation
%   gam:  "decay" (ie, tau=dt/(1-gam)
%   nu:     "baseline" (ie, C_b = nu/(1-gam)
%   rho:    jump size
% Sim.      structure of simulation parameters
%   dt:     time step size
%   Plot:   whether to plot results        (if not set, default is no)
%   MaxIter:maximum number of iterations   (typically set to 50)
%
% Output---
% n:        inferred spike train
% P:        inferred parameter structure
%
% Remarks on revisions:
% 1_7:  no longer need to define Sim.Plot (ie, if it is not defined, default
%       is to not plot, but if it is defined, one can either plot or not)
% 1_8:  cleaned up code from 1_7, and made Identity matrix outside loop,
%       which gets diagonal replaced inside loop (instead of calling speye in
%       loo)
% 1_9:  mean subtract and normalize max(F)=1 such that arbitrary scale and
%       offset shifts do no change results.
% 2:    removed normalize.  takes either a row or column vector.
%       doesn't require any Sim fields other than Sim.dt. also, we estimate
%       parameters now using FastParams code (which is the same as the one used
%       to estimate params given the real spikes, for debugging purposes)
% 2_1:  also estimate mu
% 2_2:  forgot to make this one :)
% 2_3:  fixed a bunch of bugs.  this version works to infer and learn, but
%       fixes mu in above model.
% 2_4:  to my knowledge, this one works, but requires fixing 'mu' and 'a' in
%       the above model. I also normalize between 0 and 1
% 2_41: reparameterized for stability.  uses constrained optimization. this
% works assuming nu=0 and rho=1.
% 2_42: works for arbitrary rho
% 2_43: fixed bugs so that M is only T-1 x T-1. cleaned up names and stuff.
% 2_431:made M TxT again
% 2_432:added baseline (in progress)
% 2_5:  dunno
% 2_51: removed rho and nu
% 2_52: a=alpha, b=beta, in code
% 2_53: threshold n s.t. n \in \{0,1\} before estimating parameters
% 2_54: allow for F to be a vector at each time step
% 2_55: fixed bugs, back to scalar F_t
% 2_56: back to vector case, but no param estimate
% 2_57: estimate spatial filter as well
% 2_58: multiple cells (buggy)
% 2_59: multiple cells, estimate {a,b}

%% initialize stuff

% define some stuff for brevity
Nc      = Sim.Nc;                               % # of cells
T       = Sim.T;                                % # of time steps
dt      = Sim.dt;                               % time step size
u       = 1/(2*P.sig^2);                        % scale of variance

% define some stuff for speed
Z   = zeros(Nc*T,1);                            % zero vector
M   = spdiags([repmat(-P.gam,T,1) repmat(Z,1,Nc-1) (1+Z)], -Nc:0,Nc*T,Nc*T);  % matrix transforming calcium into spikes, ie n=M*C
I   = speye(Nc*T);                              % create out here cuz it must be reused
H1  = I;                                        % initialize memory for Hessian matrix
H2  = I;                                        % another one
d0  = 1:Nc*T+1:(Nc*T)^2;                        % index of diagonal elements of TxT matrices
d1  = 1+Nc:Nc*T+1:(Nc*T)*(Nc*(T-1));            % index of diagonal elements of TxT matrices
l   = Z(1:Sim.MaxIter+10);                         % initialize likelihood
[n C DD] = FastFilter(F,P);                     % infer approximate MAP spike train, given initial parameter estimates
l_max = l;                                      % maximum likelihood achieved so far
n_best=n;                                       % best spike train
P_best=P;                                       % best parameter estimate

for i=1:Sim.MaxIter
    l(i) = Getlik2_0(DD,n,P,Sim);               % update likelihood
    if l(i)>l_max                               % if this is the best one, keep n and P
        n_best=n;
        P_best=P;
    end
    if abs(l(i+1)-l(i))<1e-4 break; end         % if li

    if Sim.plot == 1
        figure(400), nrows=1+Nc;
        for j=1:Nc, subplot(1,nrows,j),
            imagesc(reshape(z1(P.a(:,j)),Sim.w,Sim.h)),
        end
        subplot(1,nrows,nrows), imagesc(reshape(z1(P.b),Sim.w,Sim.h))
        title(['iteration ' num2str(i)]),
        figure(401), ncols=Nc+1;
        for j=1:Nc
            subplot(ncols,1,j), bar(n(:,j));
            set(gca,'XTickLabel',[])
            axis('tight')
        end
        subplot(ncols,1,ncols), plot(l(1:i))
        set(gca,'XTickLabel',[])
        drawnow
    end
    [n C DD]   = FastFilter(F,P);                  % infer approximate MAP spike train, given initial parameter estimates

    %%% estimate spatial filter
    % generate regressor
    if Sim.thresh==1
        CC=0*C;
        for j=1:Nc
            nsort   = sort(n(:,j));
            nthr    = nsort(round(0.98*T));
            nn      = Z(1:T);
            nn(n(:,j)<=nthr)=0;
            nn(n(:,j)>nthr)=1;
            CC(:,j) = filter(1,[1 -P.gam(j)],nn);
        end
        X       = [CC 1+0*Z(1:T)];
    else
        X       = [C 1+Z(1:T)];
    end
    
    % smoothed regression
    for ii=1:Sim.Np
        Y   = F(:,ii);
        B   = Y'*X*pinv(X'*X + P.smooth*I(1:Nc+1,1:Nc+1));
        for j=1:Nc
            P.a(ii,j) = B(j);
        end
        P.b(ii) = B(end);
    end
    
    %     for j=1:Nc
    %         if max(F*P.a(:,j))<0, P.a(:,j)=-P.a(:,j); end
    %     end
    
    %%% estimate other parameters
    %     nnorm   = n./repmat(max(n),Sim.T,1);
    %     P.lam   = sum(nnorm)'/(T*dt);
    %     P.sig   = sqrt(DD/T);
end

P_best.l=l;

    function [n C DD] = FastFilter(F,P)

        % initialize n and C
        z       = 1;                            % weight on barrier function
        u       = 1/(2*P.sig^2);                % scale of variance
        n       = repmat(z./P.lam,T,1);         % initialize spike train
        C       = 0*n;                          % initialize calcium
        for j=1:Nc
            C(j:Nc:end) = filter(1,[1, -P.gam(j)],n(j:Nc:end));
        end

        % precompute parameters required for evaluating and maximizing
        % likelihood
        M(d1)   = -repmat(P.gam,T-1,1);         % matrix transforming calcium into spikes, ie n=M*C
        lam     = dt*repmat(P.lam,T,1);         % for lik
        lnprior = lam.*sum(M)';                 % for grad
        aa      = repmat(diag(P.a'*P.a),T,1);   % for grad
        H1(d0)  = 2*u*aa;                       % for Hess
        gg      = (F*P.a+repmat(P.b'*P.a,T,1))';% for grad
        b       = (1+Z(1:T))*P.b';              % for lik

        % find C = argmin_{C_z} lik + prior + barrier_z
        while z>1e-13                           % this is an arbitrary threshold

            D = F-reshape(C,Nc,T)'*P.a'-b;                     % difference vector, mse=D(:)'*D(:); % ass2=(P.a'*P.a)*(C'*C) + C'*(-2*F*P.a+2*P.a'*P.b) + sum(F(:).^2) - 2*sum(F*P.b) + P.b'*P.b;
            L = u*D(:)'*D(:)+lam'*n-z*sum(log(n));  % Likilihood function using C

            s = 1;                              % step size
            d = 1;                              % direction
            while norm(d)>5e-2 && s > 1e-3      % converge for this z (again, these thresholds are arbitrary)
                g   = 2*u*(aa.*C-gg(:)) + lnprior - z*M'*(n.^-1);  % gradient
                H2(d0) = n.^-2;
                H   = H1 + z*(M'*H2*M);         % Hessian
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
                    D   = F-reshape(C1,Nc,T)'*P.a'-b;
                    DD  = D(:)'*D(:);
                    L1  = u*DD+lam'*n-z*sum(log(n));
                    s   = s/2;                  % if step increases objective function, decrease step size
                end
                C = C1;                         % update C
                L = L1;                         % update L
            end
            z=z/10;                             % reduce z (sequence of z reductions is arbitrary)
        end

        nn=reshape(Z,T,Nc);
        CC=0*nn;
        for k=1:Nc
            nn(:,k) = n(k:Nc:end);
            CC(:,k) = C(k:Nc:end);
        end
        n=nn;C=CC;
    end

end