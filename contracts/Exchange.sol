pragma solidity ^0.4.8;

import "./tokens/Token.sol";
import "./SafeMath.sol";
import "./Proxy.sol";

contract Exchange is SafeMath {

  address public PROTOCOL_TOKEN;
  address public PROXY;

  mapping (bytes32 => uint256) public fills;

  event LogFillByUser(
    address indexed maker,
    address indexed taker,
    address tokenM,
    address tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 orderHash,
    address indexed feeRecipient,
    uint256 feeM,
    uint256 feeT,
    uint256 fillValueM,
    uint256 remainingValueM
  );

  event LogFillByToken(
    address maker,
    address taker,
    address indexed tokenM,
    address indexed tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 indexed orderHash,
    address feeRecipient,
    uint256 feeM,
    uint256 feeT,
    uint256 fillValueM,
    uint256 remainingValueM
  );

  event LogCancel(
    address indexed maker,
    address indexed tokenM,
    address indexed tokenT,
    uint256 valueM,
    uint256 valueT,
    uint256 expiration,
    bytes32 orderHash,
    uint256 fillValueM,
    uint256 remainingValueM
  );

  function Exchange(address _protocolToken, address _proxy) {
    PROTOCOL_TOKEN = _protocolToken;
    PROXY = _proxy;
  }

  /*
  * Core exchange functions
  */

  /// @dev Fills an order with specified parameters and ECDSA signature.
  /// @param traders Array of order maker and taker addresses.
  /// @param feeRecipient Address that receives order fees.
  /// @param tokens Array of order tokenM and tokenT addresses.
  /// @param values Array of order valueM and valueT.
  /// @param fees Array of order feeM and feeT.
  /// @param expiration Time order expires in seconds.
  /// @param fillValueM Desired amount of tokenM to fill in order.
  /// @param v ECDSA signature parameter v.
  /// @param rs Array of ECDSA signature parameters r and s.
  /// @return Total amount of tokenM filled in trade.
  function fill(
    address[2] traders,
    address feeRecipient,
    address[2] tokens,
    uint256[2] values,
    uint256[2] fees,
    uint256 expiration,
    uint256 fillValueM,
    uint8 v,
    bytes32[2] rs)
    returns (uint256 filledValueM)
  {
    assert(block.timestamp < expiration);
    if (traders[1] != address(0)) {
      assert(traders[1] == msg.sender);
    }
    bytes32 orderHash = getOrderHash(
      traders,
      tokens,
      values,
      expiration
    );
    fillValueM = getFillValueM(orderHash, values[0], fillValueM);
    if (fillValueM > 0) {
      assert(validSignature(
        traders[0],
        getMsgHash(orderHash, feeRecipient, fees),
        v,
        rs[0],
        rs[1]
      ));
      assert(tradeTokens(
        traders[0],
        msg.sender,
        tokens,
        values,
        orderHash,
        fillValueM
      ));
      assert(tradeFees(
        traders[0],
        msg.sender,
        feeRecipient,
        values,
        fees,
        fillValueM
      ));
    }
    LogFillEvents(
      [
        traders[0],
        msg.sender,
        tokens[0],
        tokens[1],
        feeRecipient
      ],
      [
        values[0],
        values[1],
        expiration,
        fees[0],
        fees[1],
        fillValueM,
        values[0] - fills[orderHash]
      ],
      orderHash
    );
    return fillValueM;
  }

  function matchOrders(
    address[2][2] traders,
    address[2] feeRecipients,
    address[2][2] tokens,
    uint256[2][2] values,
    uint256[2][2] fees,
    uint256[2] expirations,
    uint8[2] v,
    bytes32[2][2] rs)
    returns (uint256 fillValueM1, uint256 fillValueM2)
  {
    assert(expirations[0] < block.timestamp && expirations[1] < block.timestamp);
    assert(isMatchable(tokens, values));
    if (traders[0][1] != address(0)) {
      assert(msg.sender == traders[0][1]);
    }
    if (traders[1][1] != address(0)) {
      assert(msg.sender == traders[1][1]);
    }
    bytes32 orderHash1 = getOrderHash(
      traders[0],
      tokens[0],
      values[0],
      expirations[0]
    );
    assert(validSignature(
      traders[0][0],
      getMsgHash(orderHash1, feeRecipients[0], fees[0]),
      v[0],
      rs[0][0],
      rs[0][1]
    ));
    bytes32 orderHash2 = getOrderHash(
      traders[1],
      tokens[1],
      values[1],
      expirations[1]
    );
    assert(validSignature(
      traders[1][0],
      getMsgHash(orderHash2, feeRecipients[1], fees[1]),
      v[1],
      rs[1][0],
      rs[1][1]
    ));
    return (1, 1);
  }

  /// @dev Cancels provided amount of an order with given parameters.
  /// @param traders Array of order maker and taker addresses.
  /// @param tokens Array of order tokenM and tokenT addresses.
  /// @param values Array of order valueM and valueT.
  /// @param expiration Time order expires in seconds.
  /// @param fillValueM Desired amount of tokenM to cancel in order.
  /// @return Amount of tokenM cancelled.
  function cancel(
    address[2] traders,
    address[2] tokens,
    uint256[2] values,
    uint256 expiration,
    uint256 fillValueM)
    returns (uint256 cancelledValueM)
  {
    assert(msg.sender == traders[0]);
    assert(fillValueM > 0);
    bytes32 orderHash = getOrderHash(
      traders,
      tokens,
      values,
      expiration
    );
    fillValueM = getFillValueM(orderHash, values[0], fillValueM);
    fills[orderHash] = safeAdd(fills[orderHash], fillValueM);
    LogCancel(
      traders[0],
      tokens[0],
      tokens[1],
      values[0],
      values[1],
      expiration,
      orderHash,
      fillValueM,
      values[0] - fills[orderHash]
    );
    return fillValueM;
  }

  /*
  * Constant functions
  */

  /// @dev Calculates the amount of tokenM to be filled.
  /// @param orderHash Keccak-256 hash of order.
  /// @param fillValueM Desired amount of tokenM to cancel in order.
  /// @return Amount of tokenM to fill.
  function getFillValueM(bytes32 orderHash, uint256 valueM, uint256 fillValueM)
    constant
    internal
    returns (uint256 filledValueM)
  {
    if (safeAdd(fills[orderHash], fillValueM) > valueM) {
      fillValueM = safeSub(valueM, fills[orderHash]);
    }
    return fillValueM;
  }

  /// @dev Calculates amount of tokenT to fill.
  /// @param valueM Amount of tokenM specified in order.
  /// @param valueT Amount of tokenT specified in order.
  /// @param fillValueM Amount of tokenM to be filled.
  /// @return Amount of tokenT to fill.
  function getFillValueT(uint256 valueM, uint256 valueT, uint256 fillValueM)
    constant
    internal
    returns (uint256 fillValueT)
  {
    assert(fillValueM <= valueM);
    assert(!(valueT < 10**4 && valueT * fillValueM % valueM != 0)); // throw if rounding error > 0.01%
    return safeMul(fillValueM, valueT) / valueM;
  }

  /// @dev Calculates fee to be paid for fill.
  /// @param valueM Amount of tokenM specified in order.
  /// @param fillValueM Amount of tokenM to be filled.
  /// @param fee Amount of feeM or feeT specified in order.
  /// @return Amount of feeM or feeT to be paid for fill.
  function getFeeValue(uint256 valueM, uint256 fillValueM, uint256 fee)
    constant
    internal
    returns (uint256 feeValue)
  {
    return safeDiv(safeMul(fee, fillValueM), valueM);
  }

  /// @dev Calculates Keccak-256 hash of order with specified parameters.
  /// @param traders Array of order maker and taker addresses.
  /// @param tokens Array of order tokenM and tokenT addresses.
  /// @param values Array of order valueM and valueT.
  /// @param expiration Time order expires in seconds.
  /// @return Keccak-256 hash of order.
  function getOrderHash(
    address[2] traders,
    address[2] tokens,
    uint256[2] values,
    uint256 expiration)
    constant
    returns (bytes32 orderHash)
  {
    return sha3(
      this,
      traders[0],
      traders[1],
      tokens[0],
      tokens[1],
      values[0],
      values[1],
      expiration
    );
  }

  /// @dev Calculates hash of data signed by maker.
  /// @param orderHash Keccak-256 hash of order.
  /// @param feeRecipient Address that receives order fees.
  /// @param fees Array of order feeM and feeT.
  /// @return Keccak-256 hash of orderHash and fee data.
  function getMsgHash(bytes32 orderHash, address feeRecipient, uint256[2] fees)
    constant
    returns (bytes32 msgHash)
  {
    return sha3(
      orderHash,
      feeRecipient,
      fees[0],
      fees[1]
    );
  }

  /// @dev Verifies that an order signature is valid.
  /// @param maker Address of order maker.
  /// @param msgHash Keccak-256 hash of orderHash and fee data.
  /// @param v ECDSA signature parameter v.
  /// @param r ECDSA signature parameters r.
  /// @param s ECDSA signature parameters s.
  /// @return Validity of order signature.
  function validSignature(
    address maker,
    bytes32 msgHash,
    uint8 v,
    bytes32 r,
    bytes32 s)
    constant
    returns (bool success)
  {
    return maker == ecrecover(
      sha3("\x19Ethereum Signed Message:\n32", msgHash),
      v,
      r,
      s
    );
  }

  function isMatchable(
    address[2][2] tokens,
    uint256[2][2] values
  )
    constant
    returns (bool matchable)
  {
    assert(tokens[0][0] == tokens[1][1]);
    assert(tokens[0][1] == tokens[1][0]);
    uint256 multiplier = 10**18;
    assert(safeDiv(
      safeMul(safeMul(values[0][0], values[1][0]), multiplier),
      safeMul(values[0][1], values[1][1])
    ) >= multiplier);
    return true;
  }

  /*
  * Private functions
  */

  function tradeTokens(
    address maker,
    address taker,
    address[2] tokens,
    uint256[2] values,
    bytes32 orderHash,
    uint256 fillValueM)
    private
    returns (bool success)
  {
    assert(transferFrom(
      tokens[0],
      maker,
      taker,
      fillValueM
    ));
    assert(transferFrom(
      tokens[1],
      taker,
      maker,
      getFillValueT(values[0], values[1], fillValueM)
    ));
    fills[orderHash] = safeAdd(fills[orderHash], fillValueM);
    return true;
  }

  function tradeFees(
    address maker,
    address taker,
    address feeRecipient,
    uint256[2] values,
    uint256[2] fees,
    uint256 fillValueM)
    private
    returns (bool success)
  {
    if (feeRecipient != address(0)) {
      if (fees[0] > 0) {
        assert(transferFrom(
          PROTOCOL_TOKEN,
          maker,
          feeRecipient,
          getFeeValue(values[0], fillValueM, fees[0])
        ));
      }
      if (fees[1] > 0) {
        assert(transferFrom(
          PROTOCOL_TOKEN,
          taker,
          feeRecipient,
          getFeeValue(values[0], fillValueM, fees[1])
        ));
      }
    }
    return true;
  }

  /// @dev Logs fill events indexed by user and by token.
  /// @param addresses Array of maker, taker, tokenM, tokenT, and feeRecipient addresses.
  /// @param values Array of valueM, valueT, expiration, feeM, feeT, fillValueM, and remainingValueM.
  /// @param orderHash Keccak-256 hash of order.
  function LogFillEvents(address[5] addresses, uint256[7] values, bytes32 orderHash)
    private
    returns (bool success)
  {
    LogFillByUser(
      addresses[0],
      addresses[1],
      addresses[2],
      addresses[3],
      values[0],
      values[1],
      values[2],
      orderHash,
      addresses[4],
      values[3],
      values[4],
      values[5],
      values[6]
    );
    LogFillByToken(
      addresses[0],
      addresses[1],
      addresses[2],
      addresses[3],
      values[0],
      values[1],
      values[2],
      orderHash,
      addresses[4],
      values[3],
      values[4],
      values[5],
      values[6]
    );
    return true;
  }

  /// @dev Transfers a token using Proxy transferFrom function.
  /// @param _token Address of token to transferFrom.
  /// @param _from Address transfering token.
  /// @param _to Address receiving token.
  /// @param _value Amount of token to transfer.
  /// @return Success of token transfer.
  function transferFrom(
    address _token,
    address _from,
    address _to,
    uint256 _value)
    private
    returns (bool success)
  {
    return Proxy(PROXY).transferFrom(
      _token,
      _from,
      _to,
      _value
    );
  }

  /*
  * Core exchange function derivations
  */

  /// @dev Fills all of desired fill amount of an order or nothing.
  /// @param traders Array of order maker and taker addresses.
  /// @param feeRecipient Address that receives order fees.
  /// @param tokens Array of order tokenM and tokenT addresses.
  /// @param values Array of order valueM and valueT.
  /// @param fees Array of order feeM and feeT.
  /// @param expiration Time order expires in seconds.
  /// @param fillValueM Desired amount of tokenM to fill in order.
  /// @param v ECDSA signature parameter v.
  /// @param rs Array of ECDSA signature parameters r and s.
  /// @return Success of entire fillValueM being filled.
  function fillOrKill(
    address[2] traders,
    address feeRecipient,
    address[2] tokens,
    uint256[2] values,
    uint256[2] fees,
    uint256 expiration,
    uint256 fillValueM,
    uint8 v,
    bytes32[2] rs)
    returns (bool success)
  {
    assert(fill(
      traders,
      feeRecipient,
      tokens,
      values,
      fees,
      expiration,
      fillValueM,
      v,
      rs
    ) == fillValueM);
    return true;
  }

  /// @dev Synchronously executes multiple fillOrKill orders in a single transaction.
  /// @param traders Array of order maker and taker address tuples.
  /// @param feeRecipients Array of addresses that receive order fees.
  /// @param tokens Array of order tokenM and tokenT address tuples.
  /// @param values Array of order valueM and valueT tuples.
  /// @param fees Array of order feeM and feeT tuples.
  /// @param expirations Array of times orders expire in seconds.
  /// @param fillValuesM Array of desired amounts of tokenM to fill in orders.
  /// @param v Array ECDSA signature v parameters.
  /// @param rs Array of ECDSA signature parameters r and s tuples.
  /// @return Success of all orders being filled with respective fillValueM.
  function batchFill(
    address[2][] traders,
    address[] feeRecipients,
    address[2][] tokens,
    uint256[2][] values,
    uint256[2][] fees,
    uint256[] expirations,
    uint256[] fillValuesM,
    uint8[] v,
    bytes32[2][] rs)
    returns (bool success)
  {
    for (uint256 i = 0; i < traders.length; i++) {
      assert(fillOrKill(
        traders[i],
        feeRecipients[i],
        tokens[i],
        values[i],
        fees[i],
        expirations[i],
        fillValuesM[i],
        v[i],
        rs[i]
      ));
    }
    return true;
  }

  /// @dev Synchronously executes multiple fill orders in a single transaction until total fillValueM filled.
  /// @param traders Array of order maker and taker address tuples.
  /// @param feeRecipients Array of addresses that receive order fees.
  /// @param tokens Array of order tokenM and tokenT address tuples.
  /// @param values Array of order valueM and valueT tuples.
  /// @param fees Array of order feeM and feeT tuples.
  /// @param expirations Array of times orders expire in seconds.
  /// @param fillValueM Desired total amount of tokenM to fill in orders.
  /// @param v Array ECDSA signature v parameters.
  /// @param rs Array of ECDSA signature parameters r and s tuples.
  /// @return Total amount of fillValueM filled in orders.
  function fillUntil(
    address[2][] traders,
    address[] feeRecipients,
    address[2][] tokens,
    uint256[2][] values,
    uint256[2][] fees,
    uint256[] expirations,
    uint256 fillValueM,
    uint8[] v,
    bytes32[2][] rs)
    returns (uint256 filledValueM)
  {
    address tokenM = tokens[0][0];
    uint256 fillValueMLeft = fillValueM;
    for (uint256 i = 0; i < traders.length; i++) {
      assert(tokenM == tokens[i][0]);
      fillValueMLeft = safeSub(fillValueMLeft, fill(
        traders[i],
        feeRecipients[i],
        tokens[i],
        values[i],
        fees[i],
        expirations[i],
        fillValueMLeft,
        v[i],
        rs[i]
      ));
      if (fillValueMLeft == 0) break;
    }
    return safeSub(fillValueM, fillValueMLeft);
  }



  /// @dev Synchronously cancels multiple orders in a single transaction.
  /// @param traders Array of order maker and taker address tuples.
  /// @param tokens Array of order tokenM and tokenT address tuples.
  /// @param values Array of order valueM and valueT tuples.
  /// @param expirations Array of times orders expire in seconds.
  /// @param fillValuesM Array of desired amounts of tokenM to cancel in orders.
  /// @return Success of all orders being cancelled with at least desired amounts.
  function batchCancel(
    address[2][] traders,
    address[2][] tokens,
    uint256[2][] values,
    uint256[] expirations,
    uint256[] fillValuesM)
    returns (bool success)
  {
    for (uint256 i = 0; i < traders.length; i++) {
      cancel(
        traders[i],
        tokens[i],
        values[i],
        expirations[i],
        fillValuesM[i]
      );
    }
    return true;
  }


}
