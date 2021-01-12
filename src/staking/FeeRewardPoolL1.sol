// source: https://github.com/k06a/Unipool/blob/master/contracts/Unipool.sol
// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.9;
pragma experimental ABIEncoderV2;

import { IERC20 } from "@openzeppelin/contracts-ethereum-package/contracts/token/ERC20/IERC20.sol";
import { SafeMath } from "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import { Math } from "@openzeppelin/contracts-ethereum-package/contracts/math/Math.sol";
import { PerpFiOwnableUpgrade } from "../utils/PerpFiOwnableUpgrade.sol";
import { Decimal } from "../utils/Decimal.sol";
import { DecimalERC20 } from "../utils/DecimalERC20.sol";
import { BlockContext } from "../utils/BlockContext.sol";
import { IRewardRecipient } from "../interface/IRewardRecipient.sol";
import { StakedPerpToken } from "../staking/StakedPerpToken.sol";
import { IStakeModule } from "../interface/IStakeModule.sol";

contract FeeRewardPoolL1 is IStakeModule, IRewardRecipient, PerpFiOwnableUpgrade, BlockContext, DecimalERC20 {
    using Decimal for Decimal.decimal;
    using SafeMath for uint256;

    uint256 public constant DURATION = 1 days;

    //
    // EVENTS
    //
    event RewardWithdrawn(address indexed staker, uint256 amount);
    event RewardTransferred(uint256 amount);

    //
    // MODIFIER
    //

    modifier onlyStakedPerpToken() virtual {
        require(_msgSender() == address(stakedPerpToken), "only sPerpToken");
        _;
    }

    modifier onlyTmpRewardPool() {
        require(_msgSender() == tmpRewardPool, "only tmpRewardPool");
        _;
    }

    //**********************************************************//
    //    The below state variables can not change the order    //
    //**********************************************************//

    mapping(address => Decimal.decimal) public userRewardPerTokenPaid;
    // the actual amount of rewards a staker can get
    mapping(address => Decimal.decimal) public rewards;

    // the multiplier that implies how much rewards a staked token can get
    Decimal.decimal public rewardPerTokenStored;
    // reward rate per second
    Decimal.decimal public rewardRate;

    // last reward notified time
    uint256 public lastUpdateTime;
    uint256 public periodFinish;
    uint256 public duration;

    address public tmpRewardPool;
    StakedPerpToken public stakedPerpToken;
    IERC20 public token;

    //**********************************************************//
    //    The above state variables can not change the order    //
    //**********************************************************//

    //◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤ add state variables below ◥◤◥◤◥◤◥◤◥◤◥◤◥◤◥◤//

    //◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣ add state variable, ables above ◢◣◢◣◢◣◢◣◢◣◢◣◢◣◢◣//
    uint256[50] private __gap;

    //
    // FUNCTIONS
    //
    function initialize(
        IERC20 _token,
        StakedPerpToken _stakedPerpToken,
        address _tmpRewardPool
    ) external {
        require(address(_stakedPerpToken) != address(0), "Invalid input");
        __Ownable_init();
        stakedPerpToken = _stakedPerpToken;
        tmpRewardPool = _tmpRewardPool;
        token = _token;
        duration = DURATION;
    }

    // @aduit - renaming suggestion (@phchan9)
    // It would confuse readers a bit when `notifyStake` is called by `unstake()` in
    // StakedPerpToken.sol. How about renaming `notifyStake` to `notifyStakeChanged`
    // to make it more readable?
    function notifyStakeChanged(address _staker) external override onlyStakedPerpToken {
        updateReward(_staker);
    }

    function withdrawReward() external {
        address msgSender = _msgSender();
        updateReward(msgSender);
        Decimal.decimal memory reward = rewards[msgSender];
        require(reward.toUint() > 0, "reward is 0");

        rewards[msgSender] = Decimal.zero();
        _transfer(token, msgSender, reward);
        emit RewardWithdrawn(msgSender, reward.toUint());
    }

    // assume _reward = 7, duration = 7 days and rewardRate = 1
    function notifyRewardAmount(Decimal.decimal calldata _reward) external override onlyTmpRewardPool {
        require(_reward.toUint() > 0, "invalid input");

        // @audit (@phchan9)
        // Although updateReward() will update `rewardPerTokenStored` and `lastUpdateTime`
        // to latest value, the following code only assign values to `lastUpdateTime` instead of
        // using its latest value and have no usage of `rewardPerTokenStored`.
        // Then, the statement `updateReward(address(0))` could be removed safely.
        updateReward(address(0));
        uint256 timestamp = _blockTimestamp();
        // there is no reward during the interval after the end of the previous period and before new rewards arrive
        if (timestamp >= periodFinish) {
            // rewardRate = 7/7 = 1
            rewardRate = _reward.divScalar(DURATION);
        } else {
            // assume 2 days left
            // remainingTime = 2 days
            // leftover = 1 * 2 = 2
            // rewardRate = (7 + 2) / 7 ~= 1.28
            uint256 remainingTime = periodFinish.sub(timestamp);
            Decimal.decimal memory leftover = rewardRate.mulScalar(remainingTime);
            rewardRate = _reward.addD(leftover).divScalar(DURATION);
        }

        // new period starts from now
        lastUpdateTime = timestamp;
        periodFinish = lastUpdateTime.add(DURATION);
        emit RewardTransferred(_reward.toUint());
    }

    function setDuration(uint256 _duration) external onlyOwner {
        require(_duration != 0, "invalid input");
        duration = _duration;
    }

    //
    // VIEW FUNCTIONS
    //

    function earned(address _staker) public view returns (Decimal.decimal memory) {
        return balanceOf(_staker).mulD(rewardPerToken().subD(userRewardPerTokenPaid[_staker])).addD(rewards[_staker]);
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(_blockTimestamp(), periodFinish);
    }

    function rewardPerToken() public view returns (Decimal.decimal memory) {
        if (totalSupply().toUint() == 0) {
            return rewardPerTokenStored;
        }
        // lastUpdateTime = 100 (last time notifyRewardAmount())
        // lastTimeRewardApplicable() = min(timestamp = now, periodFinish = lastUpdateTime.add(DURATION)) = depends

        uint256 timeInterval = lastTimeRewardApplicable().sub(lastUpdateTime);
        return rewardPerTokenStored.addD(rewardRate.divD(totalSupply()).mulScalar(timeInterval));
    }

    //
    // INTERNAL
    //

    function updateReward(address _staker) internal {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (_staker != address(0)) {
            rewards[_staker] = earned(_staker);
            userRewardPerTokenPaid[_staker] = rewardPerTokenStored;
        }
    }

    function balanceOf(address _staker) internal view returns (Decimal.decimal memory) {
        return Decimal.decimal(stakedPerpToken.balanceOf(_staker));
    }

    function totalSupply() internal view returns (Decimal.decimal memory) {
        return Decimal.decimal(stakedPerpToken.totalSupply());
    }
}
