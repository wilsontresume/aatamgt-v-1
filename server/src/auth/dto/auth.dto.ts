import { IsEmail, IsOptional, IsString, Matches, MaxLength, MinLength } from 'class-validator';

const USERNAME_PATTERN = /^[a-zA-Z0-9_]{3,24}$/;

export class RegisterDto {
  @IsString()
  @Matches(USERNAME_PATTERN, {
    message: 'username must be 3-24 chars of letters, numbers or underscores',
  })
  username: string;

  @IsOptional()
  @IsEmail()
  @MaxLength(190)
  email?: string;

  @IsString()
  @MinLength(8)
  @MaxLength(72)
  password: string;
}

export class LoginDto {
  @IsString()
  @MinLength(3)
  @MaxLength(190)
  identifier: string;

  @IsString()
  @MinLength(1)
  @MaxLength(72)
  password: string;
}

export class RefreshDto {
  @IsString()
  @MinLength(10)
  refreshToken: string;
}
